-module(rabbit_amqp1_0_session).

-behaviour(gen_server2).

-export([init/1, terminate/2, code_change/3,
         handle_call/3, handle_cast/2, handle_info/2]).

-export([start_link/7, process_frame/2]).

-ifdef(debug).
-export([parse_destination/1]).
-endif.

-record(session, {channel_num, backing_connection, backing_channel,
                  declaring_channel,
                  reader_pid, writer_pid, transfer_number = 0,
                  outgoing_lwm = 0, outgoing_session_credit,
                  xfer_num_to_tag }).
-record(outgoing_link, {queue,
                        transfer_count = 0,
                        transfer_unit = 0,
                        no_ack,
                        default_outcome}).

-record(incoming_link, {name, exchange, routing_key}).
-record(outgoing_transfer, {delivery_tag, expected_outcome}).

-define(SEND_ROLE, false).
-define(RECV_ROLE, true).

-define(EXCHANGE_SUB_LIFETIME, "delete-on-close").

-define(DEFAULT_OUTCOME, #'v1_0.released'{}).

-define(OUTCOMES, [?V_1_0_SYMBOL_ACCEPTED,
                   ?V_1_0_SYMBOL_REJECTED,
                   ?V_1_0_SYMBOL_RELEASED]).

-include_lib("amqp_client/include/amqp_client.hrl").
-include("rabbit_amqp1_0.hrl").

%% Session LWM and credit: (largely TODO)
%%
%% transfer-id, unsettled-lwm, and session-credit define a window:
%% |<- LWM     |<- txfr    |<- LWM + session-credit
%% [ | | | | | | | | | | | ]
%%
%% session-credit gives an offset from the lwm (it is given as txfr-id
%% in the spec, but this is a typo).  It can be used to bound the
%% amount of unsettled state.
%%
%% For incoming links, we simply echo the session credit; we are happy
%% for the client to do whatever it likes, since we don't keep track of
%% incoming messages (we're either about to settle them, or they're
%% settled when they come in; this will change if we use publisher acks).
%%
%% For outgoing links, we try to follow what the client says by using
%% basic.qos.  Unless told to change it, we try to keep an accurate
%% credit count.
%%
%% Link credit:
%% 
%% For incoming links we simply issue a large credit, and maintain it.
%% TODO reduce it if we get backpressure.
%%
%% For outgoing frames we use our basic.credit extension to AMQP 0-9-1
%% which is in bug 23749

%% TODO links can be migrated between sessions -- seriously.

%% TODO account for all these things
start_link(Channel, ReaderPid, WriterPid, _Username, _VHost,
           _Collector, _StartLimiterFun) ->
    gen_server2:start_link(
      ?MODULE, [Channel, ReaderPid, WriterPid], []).

process_frame(Pid, Frame) ->
    gen_server2:cast(Pid, {frame, Frame}).

%% ---------

init([Channel, ReaderPid, WriterPid]) ->
    %% TODO pass through authentication information
    {ok, Conn} = amqp_connection:start(direct),
    {ok, Ch} = amqp_connection:open_channel(Conn),
    {ok, #session{ channel_num        = Channel,
                   backing_connection = Conn,
                   backing_channel    = Ch,
                   reader_pid         = ReaderPid,
                   writer_pid         = WriterPid,
                   xfer_num_to_tag    = gb_trees:empty()}}.

terminate(_Reason, State = #session{ backing_connection = Conn,
                                     declaring_channel = DeclCh,
                                     backing_channel    = Ch}) ->
    ?DEBUG("Shutting down session ~p", [State]),
    case DeclCh of
        undefined -> ok;
        Channel   -> amqp_channel:close(Channel)
    end,
    amqp_channel:close(Ch),
    %% TODO: closing the connection here leads to errors in the logs
    amqp_connection:close(Conn),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_call(Msg, _From, State) ->
    {reply, {error, not_understood, Msg}, State}.

handle_info(#'basic.consume_ok'{}, State) ->
    %% Handled above
    {noreply, State};

handle_info({#'basic.deliver'{consumer_tag = ConsumerTag,
                              delivery_tag = DeliveryTag}, Msg},
            State = #session{ writer_pid = WriterPid,
                              transfer_number = TransferNum }) ->
    %% FIXME, don't ignore ack required, keep track of credit, um .. etc.
    Handle = ctag_to_handle(ConsumerTag),
    case get({out, Handle}) of
        Link = #outgoing_link{} ->
            {NewLink, NewState} =
                transfer(WriterPid, Handle, Link, State, Msg, DeliveryTag),
            put({out, Handle}, NewLink),
            {noreply, NewState#session{
                        transfer_number = next_transfer_number(TransferNum)}};
        undefined ->
            %% FIXME handle missing link -- why does the queue think it's there?
            io:format("Delivery to non-existent consumer ~p", [ConsumerTag]),
            {noreply, State}
    end;

handle_info(M = #'basic.credit_state'{}, State) ->
    %% TODO handle
    io:format("Got credit state ~p~n", [M]);

%% TODO these pretty much copied wholesale from rabbit_channel
handle_info({'EXIT', WriterPid, Reason = {writer, send_failed, _Error}},
            State = #session{writer_pid = WriterPid}) ->
    State#session.reader_pid ! {channel_exit, State#session.channel_num, Reason},
    {stop, normal, State};
handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, Reason, State};
handle_info({'DOWN', _MRef, process, _QPid, _Reason}, State) ->
    %% TODO do we care any more since we're using direct client?
    {noreply, State}. % FIXME rabbit_channel uses queue_blocked?

handle_cast({frame, Frame},
            State = #session{ writer_pid = Sock }) ->
    try handle_control(Frame, State) of
        {reply, Reply, NewState} ->
            ok = rabbit_amqp1_0_writer:send_command(Sock, Reply),
            noreply(NewState);
        {noreply, NewState} ->
            noreply(NewState);
        stop ->
            {stop, normal, State}
    catch exit:Reason = #'v1_0.error'{} ->
            %% TODO shut down nicely like rabbit_channel
            Close = #'v1_0.end'{ error = Reason },
            ok = rabbit_amqp1_0_writer:send_command(Sock, Close),
            {stop, normal, State};
          exit:normal ->
            {stop, normal, State};
          _:Reason ->
            {stop, {Reason, erlang:get_stacktrace()}, State}
    end.

%% TODO rabbit_channel returns {noreply, State, hibernate}, but that
%% appears to break things here (it stops the session responding to
%% frames).
noreply(State) ->
    {noreply, State}.

%% ------

handle_control(#'v1_0.begin'{}, State = #session{ channel_num = Channel }) ->
    {reply, #'v1_0.begin'{
       remote_channel = {ushort, Channel}}, State};

handle_control(#'v1_0.attach'{name = Name,
                              handle = Handle,
                              local = ClientLinkage,
                              transfer_unit = Unit,
                              role = ?SEND_ROLE}, %% client is sender
               State = #session{ outgoing_lwm = LWM }) ->
    %% TODO associate link name with target
    #'v1_0.linkage'{ source = Source, target = Target } = ClientLinkage,
    case ensure_target(Target, #incoming_link{ name = Name }, State) of
        {ok, ServerTarget, IncomingLink, State1} ->
            put({incoming, Handle}, IncomingLink),
            {reply,
             #'v1_0.attach'{
               name = Name,
               handle = Handle,
               remote = ClientLinkage,
               local = #'v1_0.linkage'{
                 source = Source,
                 target = ServerTarget },
               flow_state = #'v1_0.flow_state'{
                 %% we ought to be able to issue unlimited credit by
                 %% supplying a null ('undefined') here, but this is
                 %% apparently not accounted for in the Python client
                 %% code.
                 link_credit = {uint, 1000000},
                 unsettled_lwm = {uint, LWM},
                 transfer_count = {uint, 0}},
               transfer_unit = Unit,
               role = ?RECV_ROLE}, %% server is receiver
             State1};
        {error, Reason, State1} ->
            rabbit_log:warning("AMQP 1.0 attach rejected ~p~n", [Reason]),
            {reply,
             #'v1_0.attach'{
               name = Name,
               handle = Handle,
               remote = ClientLinkage,
               local = undefined}, State1},
            protocol_error(?V_1_0_INVALID_FIELD,
                               "Attach rejected: ~p", [Reason])
    end;

handle_control(#'v1_0.attach'{local = Linkage,
                              role = ?RECV_ROLE} = Attach, %% client is receiver
               State) ->
    %% TODO ensure_destination
    #'v1_0.linkage'{ source  = #'v1_0.source' {
                       default_outcome = DO,
                       outcomes = Os
                      }
                   } = Linkage,
    DefaultOutcome = case DO of
                         undefined -> ?DEFAULT_OUTCOME;
                         _         -> DO
                     end,
    Outcomes = case Os of
                   undefined -> ?OUTCOMES;
                   _         -> Os
               end,
    case lists:filter(fun(O) -> not lists:member(O, ?OUTCOMES) end, Outcomes) of
        []   -> attach_outgoing(DefaultOutcome, Outcomes, Attach, State);
        Bad  -> protocol_error(?V_1_0_NOT_IMPLEMENTED,
                               "Outcomes not supported: ~p", [Bad])
    end;

handle_control(Txfr = #'v1_0.transfer'{handle = Handle,
                                settled = Settled,
                                fragments = Fragments},
                          State = #session{backing_channel = Ch}) ->
    case get({incoming, Handle}) of
        #incoming_link{ exchange = X, routing_key = RK } ->
            Msg = rabbit_amqp1_0_message:assemble(Fragments),
            amqp_channel:call(Ch, #'basic.publish' { exchange    = X,
                                                     routing_key = RK }, Msg),
            %% TODO use publisher acknowledgement
            case Settled of
                true  -> {noreply, State};
                %% Move LWM, credit etc.
                false -> {reply,
                          acknowledgement([Txfr],
                                          #'v1_0.disposition'{
                                            role = ?RECV_ROLE}), State}
            end;
        undefined ->
            protocol_error(?V_1_0_ILLEGAL_STATE,
                           "Unknown link handle ~p", [Handle])
    end;

handle_control(#'v1_0.disposition'{ batchable = Batchable,
                                    extents = Extents,
                                    role = ?RECV_ROLE} = Disp, %% Client is receiver
               State) ->
    {SettledExtents, NewState} =
        lists:foldl(fun(Extent, {SettledExtents1, State1}) ->
                            {Settled, State2} = settle(Extent, Batchable, State1),
                            {[Settled | SettledExtents1], State2}
                    end, {[], State}, Extents),
    LWM = get_lwm(State),
    NewState1 = NewState#session { outgoing_lwm = LWM },
    case lists:filter(fun (none) -> false;
                          (_Ext)  -> true
                      end, SettledExtents) of
        []   -> {noreply, NewState1}; %% everything in its place
        Exts -> {reply,
                 Disp#'v1_0.disposition'{ extents = Exts,
                                          role = ?SEND_ROLE }, %% server is sender
                 NewState1}
    end;

handle_control(#'v1_0.detach'{ handle = Handle }, State) ->
    erase({incoming, Handle}),
    {reply, #'v1_0.detach'{ handle = Handle }, State};

handle_control(#'v1_0.end'{}, State = #session{ writer_pid = Sock }) ->
    ok = rabbit_amqp1_0_writer:send_command(Sock, #'v1_0.end'{}),
    stop;

handle_control(#'v1_0.flow'{ handle = Handle,
                             flow_state = Flow = #'v1_0.flow_state' {
                               unsettled_lwm = {uint, NewLWM},
                               link_credit = LinkCredit,
                               drain = Drain
                              }
                           },
               State = #session{ outgoing_lwm = CurrentLWM,
                                 backing_channel = Ch,
                                 writer_pid = WriterPid}) ->
    case get({outgoing, Handle}) of
        #outgoing_link{ } ->
            #'basic.credit_ok'{ available = Available } =
                amqp_channel:call(Ch, #'basic.credit'{consumer_tag = Handle,
                                                      credit       = LinkCredit,
                                                      drain        = Drain}),
            case Available of
                -1 -> ok; %% We don't know - probably because this flow relates
                          %% to a handle that does not yet exist
                          %% TODO is this an error?
                _  ->     F = #'v1_0.flow'{
                            handle = Handle,
                            flow_state = Flow#'v1_0.flow_state'{
                                          available = Available}},
                          rabbit_amqp1_0_writer:send_command(WriterPid, F)
            end;
        _ ->
            ok
    end,
    State1 = case NewLWM < CurrentLWM of
                 true ->
                     protocol_error(?V_1_0_ILLEGAL_STATE,
                                    "Attempt to roll back lwm from ~p to ~p",
                                    [CurrentLWM, NewLWM]);
                 _ ->
                     implicit_settle(NewLWM, State)
             end,
    %%% implicit settle sets the LWM
    ?DEBUG("Implicitly settled up to ~p", [NewLWM]),
    {noreply, State1};

handle_control(Frame, State) ->
    io:format("Ignoring frame: ~p~n", [Frame]),
    {noreply, State}.

%% ------

protocol_error(Condition, Msg, Args) ->
    exit(#'v1_0.error'{
        condition = Condition,
        description = {utf8, list_to_binary(
                               lists:flatten(io_lib:format(Msg, Args)))}
       }).

attach_outgoing(DefaultOutcome, Outcomes,
                #'v1_0.attach'{name = Name,
                               handle = Handle,
                               local = ClientLinkage,
                               flow_state = Flow = #'v1_0.flow_state'{
                                              session_credit = {uint, ClientSC}},
                               transfer_unit = Unit},
               State = #session{backing_channel = Ch,
                                outgoing_session_credit = ServerSC}) ->
    #'v1_0.linkage'{ source = Source } = ClientLinkage,
    NoAck = DefaultOutcome == #'v1_0.accepted'{} andalso
        Outcomes == [?V_1_0_SYMBOL_ACCEPTED],
    DOSym = rabbit_amqp1_0_framing:symbol_for(DefaultOutcome),
    case ensure_source(Source,
                       #outgoing_link{ transfer_unit = Unit,
                                       no_ack = NoAck,
                                       default_outcome = DOSym}, State) of
        {ok, Source1,
         OutgoingLink = #outgoing_link{ queue = QueueName }, State1} ->
            SessionCredit =
                case ServerSC of
                    undefined -> #'basic.qos_ok'{} =
                                     amqp_channel:call(Ch, #'basic.qos'{
                                                         prefetch_count = ClientSC}),
                                 ClientSC;
                    _         -> ServerSC
                end,
            CTag = handle_to_ctag(Handle),
            %% Default credit in 1-0 is 0. Default in 0-9-1 is infinite.
            amqp_channel:call(Ch, #'basic.credit'{consumer_tag = CTag,
                                                  credit       = 0,
                                                  drain        = true}),
            case amqp_channel:subscribe(
                   Ch, #'basic.consume' { queue = QueueName,
                                          consumer_tag = CTag,
                                          no_ack = NoAck,
                                          %% TODO exclusive?
                                          exclusive = false}, self()) of
                #'basic.consume_ok'{} ->
                    %% FIXME we should avoid the race by getting the queue to send
                    %% attach back, but a.t.m. it would use the wrong codec.
                    put({out, Handle}, OutgoingLink),
                    {reply, #'v1_0.attach'{
                       name = Name,
                       handle = Handle,
                       remote = ClientLinkage,
                       local =
                       ClientLinkage#'v1_0.linkage'{
                         source = Source1#'v1_0.source'{
                                    default_outcome = DefaultOutcome
                                    %% TODO this breaks the Python client, when it
                                    %% tries to send us back a matching detach message
                                    %% it gets confused between described(true, [...])
                                    %% and [...]. We think we're correct here
                                    %% outcomes = Outcomes
                                   }},
                       flow_state = Flow#'v1_0.flow_state'{
                                      %% transfer_count = 0,
                                      %% link_credit    = LinkCredit,
                                      %% available      = Available,
                                      %% drain          = Drain
                                     },
                       role = ?SEND_ROLE},
                     State1#session{outgoing_session_credit = SessionCredit}};
                Fail ->
                    protocol_error(?V_1_0_INTERNAL_ERROR, "Consume failed: ~p", Fail)
            end;
        {error, Reason, State1} ->
            {reply, #'v1_0.attach'{local = undefined}, State1}
    end.

transfer(WriterPid, LinkHandle,
         Link = #outgoing_link{ transfer_unit = Unit,
                                transfer_count = Count,
                                no_ack = NoAck,
                                default_outcome = DefaultOutcome },
         Session = #session{ transfer_number = TransferNumber,
                             outgoing_session_credit = SessionCredit,
                             xfer_num_to_tag = Dict },
         Msg = #amqp_msg{payload = Content},
         DeliveryTag) ->
    TransferSize = transfer_size(Content, Unit),
    NewLink = Link#outgoing_link{
                transfer_count = Count + TransferSize
               },
    NewSession = Session#session {outgoing_session_credit = SessionCredit - 1},
    T = #'v1_0.transfer'{handle = LinkHandle,
                         flow_state = flow_state(NewLink, NewSession),
                         delivery_tag = {binary, <<DeliveryTag:64>>},
                         transfer_id = {uint, TransferNumber},
                         settled = NoAck,
                         state = #'v1_0.transfer_state'{
                           %% TODO DUBIOUS this replicates information we
                           %% and the client already have
                           bytes_transferred = {ulong, 0}
                          },
                         resume = false,
                         more = false,
                         aborted = false,
                         batchable = false,
                         fragments =
                             rabbit_amqp1_0_message:fragments(Msg)},
    rabbit_amqp1_0_writer:send_command(WriterPid, T),
    Dict1 = gb_trees:insert(TransferNumber,
                            #outgoing_transfer{
                              delivery_tag = DeliveryTag,
                              expected_outcome = DefaultOutcome }, Dict),
    {NewLink, NewSession#session { xfer_num_to_tag = Dict1 }}.

settle(#'v1_0.extent'{
          first = {uint, First0},
          last = Last0,
          handle = _Handle, %% TODO DUBIOUS what on earth is this for?
          settled = Settled,
          state = #'v1_0.transfer_state'{ outcome = Outcome }
         } = Extent,
       _Batchable, %% TODO is this documented anywhere? Handle it.
       State = #session{backing_channel = Ch,
                        outgoing_session_credit = SessionCredit,
                        outgoing_lwm = LWM,
                        xfer_num_to_tag = Dict}) ->
    %% Last may be omitted, in which case it's the same as first
    Last = case Last0 of
               {uint, L} -> L;
               undefined -> First0
           end,
    %% TODO check that Last < First
    First = max(First0, LWM),
    if Last < LWM -> % FIXME it's a sequence number
            %% This is talking about transfers we've forgotten about
            {none, State};
       true ->
            {Dict1, SessionCredit1} =
                lists:foldl(
                  fun (Transfer, {TransferMap, SC}) ->
                          ?DEBUG("Settling ~p with ~p~n", [Transfer, Outcome]),
                          #outgoing_transfer{ delivery_tag = DeliveryTag }
                              = gb_trees:get(Transfer, TransferMap),
                          Ack =
                              case Outcome of
                                  #'v1_0.accepted'{} ->
                                      #'basic.ack' {delivery_tag = DeliveryTag,
                                                    multiple     = false };
                                  #'v1_0.rejected'{} ->
                                      #'basic.reject' {delivery_tag = DeliveryTag,
                                                       requeue      = false };
                                  #'v1_0.released'{} ->
                                      #'basic.reject' {delivery_tag = DeliveryTag,
                                                       requeue      = true }
                              end,
                          ok = amqp_channel:call(Ch, Ack),
                          {gb_trees:delete(Transfer, TransferMap), SC + 1}
                  end,
                  {Dict, SessionCredit}, lists:seq(max(LWM, First), Last)),
            {case Settled of
                 true  -> none;
                 false -> Extent#'v1_0.extent'{ settled = true }
             end,
             State#session{outgoing_session_credit = SessionCredit1,
                           xfer_num_to_tag = Dict1}}
    end.

implicit_settle(NewLWM, State = #session{
                          backing_channel = Ch,
                          outgoing_lwm = LWM,
                          outgoing_session_credit = SessionCredit,
                          xfer_num_to_tag = TransferMap }) ->

    if NewLWM =< LWM ->
            %% Nothing more to settle; our LWM is brought up to the new one
            ?DEBUG("(no more to implicitly settle, given LWM ~p~n)", [NewLWM]),
            State;
       true ->
            case gb_trees:is_empty(TransferMap) of
                true ->
                    %% We have been told the LWM is higher than our
                    %% _H_WM.  This may happen if we have expired
                    %% messages but not yet told anyone (if we expired
                    %% messages).
                    State;
                false ->
                    {Id, Value, NewMap} =
                        gb_trees:take_smallest(TransferMap),
                    #outgoing_transfer{ delivery_tag = DeliveryTag,
                                        expected_outcome = Outcome } = Value,
                    ?DEBUG("Implicitly settling ~p as ~p~n", [Id, Outcome]),
                    Ack =
                        case Outcome of
                            ?V_1_0_SYMBOL_ACCEPTED ->
                                #'basic.ack' {delivery_tag = DeliveryTag,
                                              multiple     = false };
                            ?V_1_0_SYMBOL_REJECTED ->
                                #'basic.reject' {delivery_tag = DeliveryTag,
                                                 requeue      = false };
                            ?V_1_0_SYMBOL_RELEASED ->
                                #'basic.reject' {delivery_tag = DeliveryTag,
                                                 requeue      = true }
                        end,
                    ok = amqp_channel:call(Ch, Ack),
                    State1 = State#session{
                               outgoing_session_credit = SessionCredit + 1,
                               outgoing_lwm = get_lwm(State),
                               xfer_num_to_tag = NewMap },
                    implicit_settle(NewLWM, State1)
            end
    end.

flow_state(#outgoing_link{transfer_count = Count},
           #session{outgoing_lwm = LWM,
                    outgoing_session_credit = SessionCredit}) ->
    #'v1_0.flow_state'{
            unsettled_lwm = {uint, LWM},
            session_credit = {uint, SessionCredit},
            transfer_count = {uint, Count},
            link_credit = {uint, 99}
           }.

acknowledgement(Txfrs, Disposition) ->
    acknowledgement(Txfrs, Disposition, []).

acknowledgement([], Disposition, Extents) ->
    %% TODO We could reverse this to be friendly to clients ..
    Disposition#'v1_0.disposition'{extents = Extents};
acknowledgement([#'v1_0.transfer'{ transfer_id = TxfrId } | Rest],
                Disposition, Exts) ->
    %% TODO coalesce extents
    Ext = #'v1_0.extent'{ first = TxfrId,
                          last = TxfrId,
                          settled = true,
                          state = #'v1_0.accepted'{}},
    acknowledgement(Rest, Disposition, [Ext | Exts]).

ensure_declaring_channel(State = #session{
                           backing_connection = Conn,
                           declaring_channel = undefined}) ->
    {ok, Ch} = amqp_connection:open_channel(Conn),
    State#session{declaring_channel = Ch};
ensure_declaring_channel(State) ->
    State.

%% There are a few things that influence what source and target
%% definitions mean for our purposes.
%%
%% Addresses: we artificially segregate exchanges and queues, since
%% they have different namespaces. However, we allow both incoming and
%% outgoing links to exchanges: outgoing links from an exchange
%% involve an anonymous queue.
%%
%% For targets, addresses are
%% Address = "/exchange/" Name
%%         | "/queue"
%%         | "/queue/" Name
%%
%% For sources, addresses are
%% Address = "/exchange/" Name "/" RoutingKey
%%         | "/queue/" Name
%%
%% We use the message property "Subject" as the equivalent of the
%% routing key.  In AMQP 0-9-1 terms, a target of /queue is equivalent
%% to the default exchange; that is, the message is routed to the
%% queue named by the subject.  A target of "/queue/Name" ignores the
%% subject.  The reason for both varieties is that a
%% dynamically-created queue must be fully addressable as a target,
%% while a service may wish to use /queue and route each message to
%% its reply-to queue name (as it is done in 0-9-1).
%%
%% A dynamic source or target only ever creates a queue, and the
%% address is returned in full; e.g., "/queue/amq.gen.123456".
%% However, that cannot be used as a reply-to, since a 0-9-1 client
%% will use it unaltered as the routing key naming the queue.
%% Therefore, we rewrite reply-to from 1.0 clients to be just the
%% queue name, and expect replying clients to use /queue and the
%% subject field.
%%
%% For a source queue, the distribution-mode is always move.  For a
%% source exchange, it is always copy. Anything else should be
%% refused.
%%
%% TODO default-outcome and outcomes, dynamic lifetimes

ensure_target(Target = #'v1_0.target'{address=Address,
                                      dynamic=Dynamic},
              Link = #incoming_link{},
              State) ->
    case Dynamic of
        undefined ->
            case Address of
                {Enc, Destination}
                when Enc =:= utf8 orelse Enc =:= utf16 ->
                    case parse_destination(Destination, Enc) of
                        ["queue", Name] ->
                            case check_queue(Name, State) of
                                {ok, QueueName, _Available, State1} ->
                                    {ok, Target,
                                     Link#incoming_link{exchange = <<"">>,
                                                        routing_key = QueueName},
                                     State1};
                                {error, Reason, State1} ->
                                    {error, Reason, State1}
                            end;
                        ["queue"] ->
                            %% Rely on the Subject being set
                            {ok, Target, Link#incoming_link{exchange = <<"">>}, State};
                        ["exchange", Name] ->
                            case check_exchange(Name, State) of
                                {ok, ExchangeName, State1} ->
                                    {ok, Target,
                                     Link#incoming_link{exchange = ExchangeName},
                                     State1};
                                {error, Reason, State2} ->
                                    {error, Reason, State2}
                            end;
                        {error, Reason} ->
                            {error, Reason, State}
                    end;
                _Else ->
                    {error, {unknown_address, Address}, State}
            end;
        {symbol, Lifetime} ->
            case Address of
                undefined ->
                    {ok, QueueName, State1} = create_queue(Lifetime, State),
                    {ok,
                     Target#'v1_0.target'{address = {utf8, queue_address(QueueName)}},
                     Link#incoming_link{exchange = <<"">>,
                                        routing_key = QueueName},
                     State1};
                _Else ->
                    {error, {both_dynamic_and_address_supplied,
                             Dynamic, Address},
                     State}
            end
    end.

ensure_source(Source = #'v1_0.source'{ address = Address,
                                       dynamic = Dynamic },
              Link = #outgoing_link{}, State) ->
    case Dynamic of
        undefined ->
            case Address of
                {Enc, Destination}
                when Enc =:= utf8 orelse Enc =:= utf16 ->
                    case parse_destination(Destination, Enc) of
                        ["queue", Name] ->
                            case check_queue(Name, State) of
                                {ok, QueueName, Available, State1} ->
                                    {ok, Source,
                                     Link#outgoing_link{
                                       queue = QueueName},
                                     State1};
                                {error, Reason, State1} ->
                                    {error, Reason, State1}
                            end;
                        ["exchange", Name, RK] ->
                            case check_exchange(Name, State) of
                                {ok, ExchangeName, State1} ->
                                    RoutingKey = list_to_binary(RK),
                                    {ok, QueueName, State2} =
                                        create_bound_queue(ExchangeName, RoutingKey,
                                                           State1),
                                    {ok, Source, Link#outgoing_link{queue = QueueName},
                                     State2};
                                {error, Reason, State1} ->
                                    {error, Reason, State1}
                            end;
                        _Otherwise ->
                            {error, {unknown_address, Address}, State}
                    end;
                _Else ->
                    {error, {malformed_address, Address}, State}
            end;
        {symbol, Lifetime} ->
            case Address of
                undefined ->
                    {ok, QueueName, State1} = create_queue(Lifetime, State),
                    {ok,
                     Source#'v1_0.source'{address = {utf8, queue_address(QueueName)}},
                     #outgoing_link{queue = QueueName},
                     State1};
                _Else ->
                    {error, {both_dynamic_and_address_supplied,
                             Dynamic, Address},
                     State}
            end
    end.

parse_destination(Destination, Enc) when is_binary(Destination) ->
    parse_destination(unicode:characters_to_list(Destination, Enc)).

parse_destination(Destination) when is_list(Destination) ->
    case regexp:split(Destination, "/") of
        {ok, ["", Type | Tail]} when
              Type =:= "queue" orelse Type =:= "exchange" ->
            [Type | Tail];
        _Else ->
            {error, {malformed_address, Destination}}
    end.

%% Check that a queue exists
check_queue(QueueName, State) when is_list(QueueName) ->
    check_queue(list_to_binary(QueueName), State);
check_queue(QueueName, State) ->
    QDecl = #'queue.declare'{queue = QueueName, passive = true},
    State1 = #session{
      declaring_channel = Channel} = ensure_declaring_channel(State),
    case catch amqp_channel:call(Channel, QDecl) of
        {'EXIT', _Reason} ->
            {error, not_found, State1#session{ declaring_channel = undefined }};
        #'queue.declare_ok'{ message_count = Available } ->
            {ok, QueueName, Available, State1}
    end.

check_exchange(ExchangeName, State) when is_list(ExchangeName) ->
    check_exchange(list_to_binary(ExchangeName), State);
check_exchange(ExchangeName, State) when is_binary(ExchangeName) ->
    XDecl = #'exchange.declare'{ exchange = ExchangeName, passive = true },
    State1 = #session{
      declaring_channel = Channel } = ensure_declaring_channel(State),
    case catch amqp_channel:call(Channel, XDecl) of
        {'EXIT', _Reason} ->
            {error, not_found, State1#session{declaring_channel = undefined}};
        #'exchange.declare_ok'{} ->
            {ok, ExchangeName, State1}
    end.

%% TODO Lifetimes: we approximate these with auto_delete, but not
%% exclusive, since exclusive queues and the direct client are broken
%% at the minute.
create_queue(_Lifetime, State) ->
    State1 = #session{ declaring_channel = Ch } = ensure_declaring_channel(State),
    #'queue.declare_ok'{queue = QueueName} =
        amqp_channel:call(Ch, #'queue.declare'{auto_delete = true}),
    {ok, QueueName, State1}.

create_bound_queue(ExchangeName, RoutingKey, State) ->
    {ok, QueueName, State1 = #session{ declaring_channel = Ch}} =
        create_queue(?EXCHANGE_SUB_LIFETIME, State),
    %% Don't both ensuring the channel, the previous should have done it
    #'queue.bind_ok'{} =
        amqp_channel:call(Ch, #'queue.bind'{ exchange = ExchangeName,
                                             queue = QueueName,
                                             routing_key = RoutingKey }),
    {ok, QueueName, State1}.

queue_address(QueueName) when is_binary(QueueName) ->
    <<"/queue/", QueueName/binary>>.

next_transfer_number(TransferNumber) ->
    %% TODO this should be a serial number
    TransferNumber + 1.

get_lwm(#session{ transfer_number = Txfr,
                  xfer_num_to_tag = Map}) ->
    case gb_trees:is_empty(Map) of
        true ->
            Txfr; 
        false ->
            {LWM, _} = gb_trees:smallest(Map),
            LWM
    end.

%% FIXME
transfer_size(_Content, _Unit) ->
    1.

handle_to_ctag({uint, H}) ->
    <<H:32/integer>>.

ctag_to_handle(<<H:32/integer>>) ->
    {uint, H}.
