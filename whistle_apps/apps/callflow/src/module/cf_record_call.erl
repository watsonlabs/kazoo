%%%-------------------------------------------------------------------
%%% @copyright (C) 2012, VoIP INC
%%% @doc
%%% Handles starting/stopping a call recording
%%%
%%% "data":{
%%%   "action":["start","stop"] // one of these
%%%   ,"time_limit":600 // in seconds, how long to record the call
%%%   ,"format":["mp3","wav"] // what format to store the recording in
%%%   ,"store_url":"http://some.server.com/store/here" // where to PUT the file
%%% }
%%% @end
%%% @contributors
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(cf_record_call).

-export([handle/2
         ,start_event_listener/2
        ]).

-include("../callflow.hrl").

-define(DEFAULT_EXTENSION, whapps_config:get(?CF_CONFIG_CAT, [<<"call_recording">>, <<"extension">>], <<"mp3">>)).
-define(DEFAULT_RECORDING_TIME_LIMIT, whapps_config:get(?CF_CONFIG_CAT, <<"max_recording_time_limit">>, 600)).
-define(DEFAULT_STORE_RECORDINGS, whapps_config:get_is_true(?CF_CONFIG_CAT, <<"store_recordings">>, 'false')).

-spec start_event_listener(whapps_call:call(), wh_json:object()) -> 'ok'.
start_event_listener(Call, Data) ->
    put('callid', whapps_call:call_id(Call)),
    TimeLimit = get_timelimit(wh_json:get_integer_value(<<"time_limit">>, Data)),
    lager:info("listening for record stop (or ~b s), then storing the recording", [TimeLimit]),

    _Wait = whapps_call_command:wait_for_headless_application(<<"record">>, <<"RECORD_STOP">>, <<"call_event">>, (TimeLimit + 10) * 1000),
    lager:info("ok, done waiting: ~p", [_Wait]),

    Format = get_format(wh_json:get_value(<<"format">>, Data)),
    MediaName = get_media_name(whapps_call:call_id(Call), Format),

    save_recording(Call, MediaName, Format, wh_json:get_value(<<"store_url">>, Data)).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec handle(wh_json:object(), whapps_call:call()) -> 'ok'.
handle(Data, Call) ->
    Action = get_action(wh_json:get_value(<<"action">>, Data)),
    handle(Data, Call, Action),
    cf_exe:continue(Call).

handle(Data, Call, <<"start">> = Action) ->
    TimeLimit = get_timelimit(wh_json:get_integer_value(<<"time_limit">>, Data)),

    Format = get_format(wh_json:get_value(<<"format">>, Data)),
    MediaName = get_media_name(whapps_call:call_id(Call), Format),

    _P = cf_exe:add_event_listener(Call, {?MODULE, 'start_event_listener', [Data]}),

    lager:info("recording ~s starting, evt listener at ~p", [MediaName, _P]),
    whapps_call_command:record_call(MediaName, Action, TimeLimit, Call);
handle(Data, Call, <<"stop">> = Action) ->
    Format = get_format(wh_json:get_value(<<"format">>, Data)),
    MediaName = get_media_name(whapps_call:call_id(Call), Format),

    _ = whapps_call_command:record_call(MediaName, Action, Call),
    lager:info("recording of ~s stopped", [MediaName]),

    save_recording(Call, MediaName, Format, wh_json:get_value(<<"store_url">>, Data)).

-spec save_recording(whapps_call:call(), ne_binary(), ne_binary(), api_binary()) -> 'ok'.
save_recording(Call, MediaName, Format, 'undefined') ->
    case ?DEFAULT_STORE_RECORDINGS of
        'true' -> save_to_couch(Call, MediaName, Format);
        'false' ->
            lager:error("failed to save recording ~s, disallowed to save to couch", [MediaName])
    end;
save_recording(Call, MediaName, Format, BaseUrl) ->
    StoreUrl = wapi_dialplan:offsite_store_url(BaseUrl, MediaName),
    lager:info("trying to store ~s in callflow-supplied url: ~s", [MediaName, StoreUrl]),

    {'ok', _} = store_recording_meta(Call, MediaName, Format, <<"private_remote_media">>
                                         ,[{<<"remote_media_url">>, StoreUrl}]
                                    ),
    store_recording(MediaName, StoreUrl, Call).

-spec save_to_couch(whapps_call:call(), ne_binary(), ne_binary()) -> 'ok'.
save_to_couch(Call, MediaName, Format) ->
    lager:info("trying to store recording ~s", [MediaName]),
    {'ok', MediaJObj} = store_recording_meta(Call, MediaName, Format, <<"private_media">>),
    store_recording(MediaName, store_url(Call, MediaJObj), Call).

-spec store_recording(ne_binary(), ne_binary(), whapps_call:call()) -> 'ok'.
store_recording(MediaName, StoreUrl, Call) ->
    'ok' = whapps_call_command:store(MediaName, StoreUrl, Call).

-spec get_action(api_binary()) -> ne_binary().
get_action('undefined') -> <<"start">>;
get_action(<<"stop">>) -> <<"stop">>;
get_action(_) -> <<"start">>.

-spec get_timelimit(wh_timeout()) -> pos_integer().
get_timelimit('undefined') -> ?DEFAULT_RECORDING_TIME_LIMIT;
get_timelimit(TL) ->
    case (Max = ?DEFAULT_RECORDING_TIME_LIMIT) > TL of
        'true' -> TL;
        'false' when Max > 0 -> Max;
        'false' -> Max
    end.

-spec get_format(api_binary()) -> ne_binary().
get_format('undefined') -> ?DEFAULT_EXTENSION;
get_format(<<"mp3">> = MP3) -> MP3;
get_format(<<"wav">> = WAV) -> WAV;
get_format(_) -> get_format('undefined').

-spec store_recording_meta(whapps_call:call(), ne_binary(), api_binary(), ne_binary()) ->
                                  {'ok', wh_json:object()} |
                                  {'error', any()}.
-spec store_recording_meta(whapps_call:call(), ne_binary(), api_binary(), ne_binary(), wh_proplist()) ->
                                  {'ok', wh_json:object()} |
                                  {'error', any()}.
store_recording_meta(Call, MediaName, Ext, PvtType) ->
    store_recording_meta(Call, MediaName, Ext, PvtType, []).
store_recording_meta(Call, MediaName, Ext, PvtType, Fields) ->
    AcctDb = whapps_call:account_db(Call),
    CallId = whapps_call:call_id(Call),

    MediaDoc = wh_doc:update_pvt_parameters(
                 wh_json:from_list(
                   [{<<"name">>, MediaName}
                    ,{<<"description">>, <<"recording ", MediaName/binary>>}
                    ,{<<"content_type">>, ext_to_mime(Ext)}
                    ,{<<"media_type">>, Ext}
                    ,{<<"media_source">>, <<"recorded">>}
                    ,{<<"source_type">>, wh_util:to_binary(?MODULE)}
                    ,{<<"pvt_type">>, PvtType}
                    ,{<<"from">>, whapps_call:from(Call)}
                    ,{<<"to">>, whapps_call:to(Call)}
                    ,{<<"caller_id_number">>, whapps_call:caller_id_number(Call)}
                    ,{<<"caller_id_name">>, whapps_call:caller_id_name(Call)}
                    ,{<<"call_id">>, CallId}
                    ,{<<"_id">>, get_recording_doc_id(CallId)}
                    | Fields
                   ])
                 ,AcctDb
                ),
    couch_mgr:save_doc(AcctDb, MediaDoc).

ext_to_mime(<<"wav">>) -> <<"audio/x-wav">>;
ext_to_mime(_) -> <<"audio/mp3">>.

get_recording_doc_id(CallId) -> <<"call_recording_", CallId/binary>>.

-spec get_media_name(ne_binary(), api_binary()) -> ne_binary().
get_media_name(CallId, Ext) ->
    <<(get_recording_doc_id(CallId))/binary, ".", Ext/binary>>.

-spec store_url(whapps_call:call(), wh_json:object()) -> ne_binary().
store_url(Call, JObj) ->
    AccountDb = whapps_call:account_db(Call),
    MediaId = wh_json:get_value(<<"_id">>, JObj),
    MediaName = wh_json:get_value(<<"name">>, JObj),
    {'ok', URL} = wh_media_url:store(AccountDb, MediaId, MediaName),
    URL.
