-module(ems_http).
-export([start_link/1, stop/0, handle_http/1]).
-include("../include/ems.hrl").

% start misultin http server
start_link(Port) ->
	misultin:start_link([{port, Port}, {loop, fun handle_http/1}]).

% stop misultin
stop() ->
	misultin:stop().

% callback on request received
handle_http(Req) ->	
  random:seed(now()),
  handle(Req:get(method), Req:resource([urldecode]), Req).


handle('GET', [], Req) ->
  erlydtl:compile("wwwroot/index.html", index_template),
  
  Query = Req:parse_qs(),
  io:format("GET / ~p~n", [Query]),
  File = proplists:get_value("file", Query, "video.mp4"),
  case file:list_dir(file_play:file_dir()) of
    {ok, FileList} -> ok;
    {error, Error} -> 
      FileList = [],
      error_logger:error_msg("Invalid HTTP root directory: ~p (~p)~n", [file_play:file_dir(), Error])
  end,
  {ok, Index} = index_template:render([
    {files, FileList},
    {hostname, ems:get_var(host, "rtmp://localhost")},
    {live_id, uuid:to_string(uuid:v4())},
    {url, File},
    {session, rtmp_session:encode([{channels, [10, 12]}, {user_id, 5}]) }]),
  Req:ok([{'Content-Type', "text/html; charset=utf8"}], Index);


handle('GET', ["admin"], Req) ->
  erlydtl:compile("wwwroot/admin.html", admin_template),
  % {ok, Contents} = file:read_file("player/player.html"),

  Entries = media_provider:entries(),
  {ok, Index} = admin_template:render([
  {entries, Entries}]),
  Req:ok([{'Content-Type', "text/html; charset=utf8"}], Index);


handle('GET', ["chat.html"], Req) ->
  erlydtl:compile("wwwroot/chat.html", chat_template),
  % {ok, Contents} = file:read_file("player/player.html"),

  {ok, Index} = chat_template:render([
    {hostname, ems:get_var(host, "rtmp://localhost")},
    {session, rtmp_session:encode([{channels, [10, 12]}, {user_id, 5}])}
  ]),
  Req:ok([{'Content-Type', "text/html; charset=utf8"}], Index);

  
handle('POST', ["open", ChunkNumber], Req) ->
  error_logger:info_msg("Request: open/~p.\n", [ChunkNumber]),
  SessionId = generate_session_id(),
  <<Timeout>> = Req:get(body),
  {ok, _Pid} = rtmpt_client:start(SessionId),
  error_logger:info_msg("Opened session ~p, timeout ~p.\n", [SessionId, Timeout]),
  Req:ok([{'Content-Type', ?CONTENT_TYPE}, ?SERVER_HEADER], [SessionId, "\n"]);
  
handle('POST', ["idle", SessionId, SequenceNumber], Req) ->
  % error_logger:info_msg("Request: idle/~p/~p.\n", [SessionId, SequenceNumber]),
  case ets:match_object(rtmp_sessions, {SessionId, '$2'}) of
      [{SessionId, Rtmp}] ->
          {Buffer} = gen_fsm:sync_send_event(Rtmp, {recv, list_to_int(SequenceNumber)}),
          % io:format("Returning ~p~n", [size(Buffer)]),
          Req:ok([{'Content-Type', ?CONTENT_TYPE}, ?SERVER_HEADER], [33, Buffer]);
      _ ->
          error_logger:info_msg("Request 'idle' to closed session ~p\n", [SessionId]),
          Req:stream(<<0>>),
          Req:stream(close)
  end;


handle('POST', ["send", SessionId, SequenceNumber], Req) ->
  % error_logger:info_msg("Request: send/~p/~p.\n", [SessionId, SequenceNumber]),
  case ets:match_object(rtmp_sessions, {SessionId, '$2'}) of
      [{SessionId, Rtmp}] ->
          gen_fsm:send_event(Rtmp, {client_data, Req:get(body)}),
          {Buffer} = gen_fsm:sync_send_event(Rtmp, {recv, list_to_int(SequenceNumber)}),
          % io:format("Returning ~p~n", [size(Buffer)]),
          Req:ok([{'Content-Type', ?CONTENT_TYPE}, ?SERVER_HEADER], [33, Buffer]);
      _ ->
          error_logger:info_msg("Request 'idle' to closed session ~p\n", [SessionId]),
          Req:stream(<<0>>),
          Req:stream(close)
  end;
  
  
handle('POST', ["close", SessionId, ChunkNumber], Req) ->
    error_logger:info_msg("Request: close/~p/~p.\n", [SessionId, ChunkNumber]),
    Req:stream(<<0>>),
    Req:stream(close);
    
handle('POST', ["fcs", "ident", ChunkNumber], Req) ->
    error_logger:info_msg("Request: ident/~p.\n", [ChunkNumber]),
    Req:ok([{'Content-Type', ?CONTENT_TYPE}, ?SERVER_HEADER], "0.1");
    
handle('POST', ["fcs", "ident2"], Req) ->
    error_logger:info_msg("Request: ident2.\n"),
    Req:ok([{'Content-Type', ?CONTENT_TYPE}, ?SERVER_HEADER], "0.1");
  
handle('POST', ["channels", ChannelS, "message"], Req) ->
  Message = proplists:get_value("message", Req:parse_post()),
  Channel = list_to_integer(ChannelS),
  rtmp_server:send_to_channel(Channel, Message),
  Req:respond(200, [{"Content-Type", "text/plain"}], "200 OK\n");

handle('POST', ["users", UserS, "message"], Req) ->
  Message = proplists:get_value("message", Req:parse_post()),
  User = list_to_integer(UserS),
  rtmp_server:send_to_user(User, Message),
  Req:respond(200, [{"Content-Type", "text/plain"}], "200 OK\n");

  
handle('GET', ["stream", Name], Req) ->
  case media_provider:play(Name) of
    {ok, PlayerPid} ->
      mpeg_ts:play(Name, PlayerPid, Req);
    {notfound} ->
      Req:respond(404, [{"Content-Type", "text/plain"}], "404 Page not found. ~p: ~p", [Name, Req]);
    Reason -> 
      Req:respond(500, [{"Content-Type", "text/plain"}], "500 Internal Server Error.~n Failed to start video player: ~p~n ~p: ~p", [Reason, Name, Req])
  end;
  
handle('GET', Path, Req) ->
  FileName = filename:absname(filename:join(["wwwroot" | Path])),
  case filelib:is_regular(FileName) of
    true ->
      ?D({"GET", FileName}),
      Req:file(FileName);
    false ->
      Req:respond(404, [{"Content-Type", "text/plain"}], "404 Page not found. ~p: ~p", [Path, Req])
  end;

  
% handle the 404 page not found
handle(_, Path, Req) ->
	Req:respond(404, [{"Content-Type", "text/plain"}], "404 Page not found. ~p: ~p", [Path, Req]).




-spec generate_session_id() -> list().
generate_session_id() ->
    {T1, T2, T3} = now(),
    lists:flatten(io_lib:format("~p:~p:~p", [T1, T2, T3])).


-spec list_to_int(list()) -> integer().
list_to_int(String) ->
    case io_lib:fread("~u", String) of
        {ok, [Num], _} ->
            Num;
        _ -> undefined
    end.
