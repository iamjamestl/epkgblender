%%%
%%% epkgblender_user_server.erl
%%% Copyright (C) 2011 James Lee
%%% 
%%% This program is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program.  If not, see <http://www.gnu.org/licenses/>.
%%%

-module(epkgblender_user_server).
-author("James Lee <jlee@thestaticvoid.com>").
-behaviour(gen_server).
-export([start_link/0, register_user/4, validate_email/2, authenticate/4, remember_me_login/2, logout/2, user_exists/1, email_registered/1, remove_old_remember_me_tokens/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("stdlib/include/qlc.hrl").
-include("epkgblender.hrl").

%%
%% API
%%
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register_user(Username, Password, Name, Email) ->
    gen_server:call(?MODULE, {register_user, Username, Password, Name, Email}).

validate_email(Username, ValidationToken) ->
    gen_server:call(?MODULE, {validate_email, Username, ValidationToken}).

authenticate(Username, Password, RememberMe, OldRememberMeSeries) ->
    gen_server:call(?MODULE, {authenticate, Username, Password, RememberMe, OldRememberMeSeries}).

remember_me_login(Series, Token) ->
    gen_server:call(?MODULE, {remember_me_login, Series, Token}).

logout(Username, RememberMeSeries) ->
    gen_server:cast(?MODULE, {logout, Username, RememberMeSeries}).

user_exists(Username) ->
    gen_server:call(?MODULE, {user_exists, Username}).

email_registered(Email) ->
    gen_server:call(?MODULE, {email_registered, Email}).

remove_old_remember_me_tokens() ->
    gen_server:cast(?MODULE, remove_old_remember_me_tokens).


%%
%% Callbacks
%%
init([]) ->
    mnesia:create_table(epkgblender_user, [{disc_copies, [node()]}, {attributes, record_info(fields, epkgblender_user)}]),
    {ok, []}.

handle_call({register_user, Username, Password, Name, Email}, _From, State) ->
    {ok, Salt} = bcrypt:gen_salt(),
    {ok, PasswordHash} = bcrypt:hashpw(Password, Salt),
    User = #epkgblender_user{username = Username, password_hash = PasswordHash, name = Name, email = Email},

    F = fun() ->
        case {get_user(Username), get_user_by_email(Email)} of
            {{ok, _}, _} ->
                mnesia:abort(user_already_exists);
            {_, {ok, _}} ->
                mnesia:abort(email_already_registered);
            _ ->
                mnesia:write(User)
        end
    end,

    case mnesia:transaction(F) of
        {aborted, user_already_exists} ->
            {reply, {error, user_already_exists}, State};
        {aborted, email_already_registered} ->
            {reply, {error, email_already_registered}, State};
        {atomic, ok} ->
            NewUser = generate_email_validation(User),
            {reply, {ok, NewUser}, State}
    end;

handle_call({validate_email, Username, ValidationToken}, _From, State) ->
    {ok, User} = get_user(Username),
    case User#epkgblender_user.validation_token of
        % User is already validated if their token is empty
        "" ->
            {reply, already_validated, State};

        % If the input token matches the one in the database
        ValidationToken ->
            NewUser = User#epkgblender_user{validation_token = "", roles = [user|User#epkgblender_user.roles]},
            F = fun() ->
                case get_user_by_email(User#epkgblender_user.email) of
                    {error, no_such_user} ->
                        mnesia:write(NewUser);
                    {ok, _User} ->
                        mnesia:abort(email_already_registered)
                end
            end,
            case mnesia:transaction(F) of
                {aborted, email_already_registered} ->
                    {reply, email_already_registered, State};
                {atomic, ok} ->
                    {reply, {ok, NewUser}, State} 
            end;

        _ ->
            NewUser = generate_email_validation(User),
            {reply, {bad_validation_token, NewUser}, State}
    end;

handle_call({authenticate, Username, Password, RememberMe, OldRememberMeSeries}, _From, State) ->
    case get_user(Username) of
        {ok, User} ->
            PasswordHash = User#epkgblender_user.password_hash,
            case bcrypt:hashpw(Password, PasswordHash) of
                % if the password matches
                {ok, PasswordHash} ->
                    % remove the old remember-me token from the database
                    Tokens = lists:keydelete(OldRememberMeSeries, 1, User#epkgblender_user.remember_me_tokens),

                    {Token, NewTokens} = case RememberMe of
                        true ->
                            RememberMeToken = generate_remember_me_token(),
                            {RememberMeToken, [RememberMeToken|Tokens]};
                        false ->
                            {nil, Tokens}
                    end,
                            
                    mnesia:transaction(fun() -> mnesia:write(User#epkgblender_user{remember_me_tokens = NewTokens}) end),
                    {reply, {ok, [password|User#epkgblender_user.roles], Token}, State};
                _ ->
                    {reply, {error, bad_auth}, State}
            end;
        {error, no_such_user} ->
            {reply, {error, bad_auth}, State}
    end;

handle_call({remember_me_login, Series, Token}, _From, State) ->
    case get_user_by_remember_me_series(Series) of
        {error, no_such_user} ->
            {reply, {error, bad_series}, State};
        {ok, User} ->
            case lists:keyfind(Series, 1, User#epkgblender_user.remember_me_tokens) of
                {Series, Token, _LastUsed} ->
                    NewToken = generate_remember_me_token(Series),
                    NewTokens = lists:keystore(Series, 1, User#epkgblender_user.remember_me_tokens, NewToken),
                    mnesia:transaction(fun() -> mnesia:write(User#epkgblender_user{remember_me_tokens = NewTokens}) end),
                    {reply, {ok, User#epkgblender_user.username, User#epkgblender_user.roles, NewToken}, State};
                _ -> % non maching token -> theft assumed
                    mnesia:transaction(fun() -> mnesia:write(User#epkgblender_user{remember_me_tokens = []}) end),
                    {reply, {error, bad_token}, State}
            end
    end;

handle_call({user_exists, Username}, _From, State) ->
    case get_user(Username) of
        {ok, _User} ->
            {reply, true, State};
        {error, no_such_user} ->
            {reply, false, State}
    end;

handle_call({email_registered, Email}, _From, State) ->
    case get_user_by_email(Email) of
        {ok, _User} ->
            {reply, true, State};
        {error, no_such_user} ->
            {reply, false, State}
    end;

handle_call(_Msg, _From, State) -> {noreply, State}.

handle_cast({logout, Username, RememberMeSeries}, State) ->
    case get_user(Username) of
        {ok, User} ->
            Tokens = lists:keydelete(RememberMeSeries, 1, User#epkgblender_user.remember_me_tokens),
            mnesia:transaction(fun() -> mnesia:write(User#epkgblender_user{remember_me_tokens = Tokens}) end);
        {error, no_such_user} ->
            ok
    end,
    {noreply, State};

handle_cast(remove_old_remember_me_tokens, State) ->
    LocalTimeSeconds = calendar:datetime_to_gregorian_seconds(erlang:localtime()),
    mnesia:transaction(fun() ->
        UsersToUpdate = mnesia:foldl(fun(User, Acc) ->
            Tokens = lists:filter(fun({_, _, LastUsed}) ->
                (LocalTimeSeconds - calendar:datetime_to_gregorian_seconds(LastUsed)) / 60 =< ?REMEMBER_ME_TTL
            end, User#epkgblender_user.remember_me_tokens),

            case Tokens =/= User#epkgblender_user.remember_me_tokens of
                true -> [User#epkgblender_user{remember_me_tokens = Tokens}|Acc];
                false -> Acc
            end
        end, [], epkgblender_user),

        lists:foreach(fun(User) -> mnesia:write(User) end, UsersToUpdate)
    end),
    {noreply, State};

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.


%%
%% Private Functions
%%
generate_email_validation(User) ->
    ValidationToken = bin_to_hexstr(crypto:rand_bytes(16)),
    NewUser = User#epkgblender_user{validation_token = ValidationToken},
    mnesia:transaction(fun() -> mnesia:write(NewUser) end),
    NewUser.

generate_remember_me_token() ->
    Series = bin_to_hexstr(crypto:rand_bytes(16)),
    case get_user_by_remember_me_series(Series) of
        {ok, _User} ->
            generate_remember_me_token();
        {error, no_such_user} ->
            generate_remember_me_token(Series)
    end.

generate_remember_me_token(Series) ->
    {Series, bin_to_hexstr(crypto:rand_bytes(16)), erlang:localtime()}.

get_user_by_remember_me_series(Series) ->
    F = fun() ->
        qlc:e(qlc:q([U || U <- mnesia:table(epkgblender_user),
                          lists:keyfind(Series, 1, U#epkgblender_user.remember_me_tokens) =/= false]))
    end,
    case mnesia:transaction(F) of
        {atomic, []} -> {error, no_such_user};
        {atomic, [User]} -> {ok, User}
    end.

bin_to_hexstr(Bin) ->
    lists:flatten([io_lib:format("~2.16.0b", [X]) || X <- binary_to_list(Bin)]).

get_user(Username) ->
    case mnesia:transaction(fun() -> mnesia:read({epkgblender_user, Username}) end) of
        {atomic, []} -> {error, no_such_user};
        {atomic, [User]} -> {ok, User}
    end.

get_user_by_email(Email) ->
    F = fun() ->
        qlc:e(qlc:q([U || U <- mnesia:table(epkgblender_user),
                          U#epkgblender_user.email == Email,
                          U#epkgblender_user.validation_token == ""]))
    end,

    case mnesia:transaction(F) of
        {atomic, []} -> {error, no_such_user};
        {atomic, [User]} -> {ok, User}
    end.
