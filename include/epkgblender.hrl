%% Nitrogen elements
-include_lib("nitrogen_core/include/wf.hrl").
-record(epkgblender_table, {?ELEMENT_BASE(epkgblender_table), rows, header = [], footer = []}).
-record(epkgblender_recaptcha, {?ELEMENT_BASE(epkgblender_recaptcha), pubkey}).
-record(epkgblender_recaptcha_validator, {?VALIDATOR_BASE(epkgblender_recaptcha), privkey}).

%% mnesia tables
-record(epkgblender_user, {username, password_hash, name, email, validation_token = "", enabled = false, roles = []}).
