%%--------------------------------------------------------------------
%% Copyright (c) 2012-2016 Feng Lee <feng@emqtt.io>.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqttd_pubsub).

-author("Feng Lee <feng@emqtt.io>").

-behaviour(gen_server2).

-include("emqttd.hrl").

-include("emqttd_protocol.hrl").

-include("emqttd_internal.hrl").

%% Start
-export([start_link/3]).

%% PubSub API.
-export([subscribe/1, subscribe/2, subscribe/3, publish/2,
         unsubscribe/1, unsubscribe/2]).

%% Async PubSub API.
-export([async_subscribe/1, async_subscribe/2, async_subscribe/3,
         async_unsubscribe/1, async_unsubscribe/2]).

-export([subscriber_down/1]).

%% Management API.
-export([setqos/3, is_subscribed/2, subscriptions/1]).

%% Debug API
-export([dump/0]).

%% gen_server.
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {pool, id, env, submon :: emqttd_pmon:pmon()}).

-define(PUBSUB, ?MODULE).

-define(Dispatcher, emqttd_dispatcher).

%% @doc Start a pubsub server
-spec(start_link(atom(), pos_integer(), [tuple()]) -> {ok, pid()} | ignore | {error, any()}).
start_link(Pool, Id, Env) ->
    gen_server2:start_link({local, ?PROC_NAME(?PUBSUB, Id)}, ?MODULE, [Pool, Id, Env], []).

%%--------------------------------------------------------------------
%% PubSub API
%%--------------------------------------------------------------------

%% @doc Subscribe a Topic
-spec(subscribe(binary()) -> ok | emqttd:pubsub_error()).
subscribe(Topic) when is_binary(Topic) ->
    subscribe(Topic, self()).

-spec(subscribe(binary(), emqttd:subscriber()) -> ok | emqttd:pubsub_error()).
subscribe(Topic, Subscriber) when is_binary(Topic) ->
    subscribe(Topic, Subscriber, []).

-spec(subscribe(binary(), emqttd:subscriber(), [emqttd:suboption()]) ->
      ok | emqttd:pubsub_error()).
subscribe(Topic, Subscriber, Options) when is_binary(Topic) ->
    call(pick(Subscriber), {subscribe, Topic, Subscriber, Options}).

%% @doc Subscribe a Topic Asynchronously
-spec(async_subscribe(binary()) -> ok).
async_subscribe(Topic) when is_binary(Topic) ->
    async_subscribe(Topic, self()).

-spec(async_subscribe(binary(), emqttd:subscriber()) -> ok).
async_subscribe(Topic, Subscriber) when is_binary(Topic) ->
    async_subscribe(Topic, Subscriber, []).

-spec(async_subscribe(binary(), emqttd:subscriber(), [emqttd:suboption()]) -> ok).
async_subscribe(Topic, Subscriber, Options) when is_binary(Topic) ->
    cast(pick(Subscriber), {subscribe, Topic, Subscriber, Options}).

subscriber_down(Subscriber) ->
    cast(pick(Subscriber), {down, Subscriber}).

%% @doc Publish message to Topic.
-spec(publish(binary(), any()) -> {ok, mqtt_delivery()} | ignore).
publish(Topic, Msg) when is_binary(Topic) ->
    route(emqttd_router:match(Topic), delivery(Msg)).

%% Dispatch on the local node
route([#mqtt_route{topic = To, node = Node}],
      Delivery = #mqtt_delivery{flows = Flows}) when Node =:= node() ->
    ?Dispatcher:dispatch(To, Delivery#mqtt_delivery{flows = [{route, Node, To} | Flows]});

%% Forward to other nodes
route([#mqtt_route{topic = To, node = Node}], Delivery = #mqtt_delivery{flows = Flows}) ->
    forward(Node, To, Delivery#mqtt_delivery{flows = [{route, Node, To}|Flows]});

route(Routes, Delivery) ->
    {ok, lists:foldl(fun(Route, DelAcc) ->
                    {ok, DelAcc1} = route([Route], DelAcc), DelAcc1
            end, Delivery, Routes)}.

delivery(Msg) -> #mqtt_delivery{message = Msg, flows = []}.

%% @doc Forward message to another node...
forward(Node, To, Delivery) ->
    rpc:cast(Node, ?Dispatcher, dispatch, [To, Delivery]), {ok, Delivery}.

subscriptions(Subscriber) ->
    lists:map(fun({_, Topic}) ->
                subscription(Topic, Subscriber)
        end, ets:lookup(mqtt_subscription, Subscriber)).

subscription(Topic, Subscriber) ->
    {Topic, ets:lookup_element(mqtt_pubsub, {Topic, Subscriber}, 2)}.

is_subscribed(Topic, Subscriber) when is_binary(Topic) ->
    ets:member(mqtt_pubsub, {Topic, Subscriber}).

setqos(Topic, Subscriber, Qos) when is_binary(Topic) ->
    call(pick(Subscriber), {setqos, Topic, Subscriber, Qos}).

dump() ->
    [{Tab, ets:tab2list(Tab)} || Tab <- [mqtt_pubsub, mqtt_subscription, mqtt_subscriber]].

%% @doc Unsubscribe
-spec(unsubscribe(binary()) -> ok | emqttd:pubsub_error()).
unsubscribe(Topic) when is_binary(Topic) ->
    unsubscribe(Topic, self()).

%% @doc Unsubscribe
-spec(unsubscribe(binary(), emqttd:subscriber()) -> ok | emqttd:pubsub_error()).
unsubscribe(Topic, Subscriber) when is_binary(Topic) ->
    call(pick(Subscriber), {unsubscribe, Topic, Subscriber}).

%% @doc Async Unsubscribe
-spec(async_unsubscribe(binary()) -> ok).
async_unsubscribe(Topic) when is_binary(Topic) ->
    async_unsubscribe(Topic, self()).

-spec(async_unsubscribe(binary(), emqttd:subscriber()) -> ok).
async_unsubscribe(Topic, Subscriber) when is_binary(Topic) ->
    cast(pick(Subscriber), {unsubscribe, Topic, Subscriber}).

call(PubSub, Req) when is_pid(PubSub) ->
    gen_server2:call(PubSub, Req, infinity).

cast(PubSub, Msg) when is_pid(PubSub) ->
    gen_server2:cast(PubSub, Msg).

pick(Subscriber) ->
    gproc_pool:pick_worker(pubsub, Subscriber).

%%--------------------------------------------------------------------
%% gen_server Callbacks
%%--------------------------------------------------------------------

init([Pool, Id, Env]) ->
    ?GPROC_POOL(join, Pool, Id),
    {ok, #state{pool = Pool, id = Id, env = Env, submon = emqttd_pmon:new()}}.

handle_call({subscribe, Topic, Subscriber, Options}, _From, State) ->
    case do_subscribe(Topic, Subscriber, Options, State) of
        {ok, NewState} -> {reply, ok, setstats(NewState)};
        {error, Error} -> {reply, {error, Error}, State}
    end;

handle_call({unsubscribe, Topic, Subscriber}, _From, State) ->
    case do_unsubscribe(Topic, Subscriber, State) of
        {ok, NewState} -> {reply, ok, setstats(NewState), hibernate};
        {error, Error} -> {reply, {error, Error}, State}
    end;

handle_call({setqos, Topic, Subscriber, Qos}, _From, State) ->
    Key = {Topic, Subscriber},
    case ets:lookup(mqtt_pubsub, Key) of
        [{_, Opts}] ->
            Opts1 = lists:ukeymerge(1, [{qos, Qos}], Opts),
            ets:insert(mqtt_pubsub, {Key, Opts1}),
            {reply, ok, State};
        [] ->
            {reply, {error, {subscription_not_found, Topic}}, State}
    end;

handle_call(Req, _From, State) ->
    ?UNEXPECTED_REQ(Req, State).

handle_cast({subscribe, Topic, Subscriber, Options}, State) ->
    case do_subscribe(Topic, Subscriber, Options, State) of
        {ok, NewState}  -> {noreply, setstats(NewState)};
        {error, _Error} -> {noreply, State}
    end;

handle_cast({unsubscribe, Topic, Subscriber}, State) ->
    case do_unsubscribe(Topic, Subscriber, State) of
        {ok, NewState}  -> {noreply, setstats(NewState), hibernate};
        {error, _Error} -> {noreply, State}
    end;

handle_cast({down, Subscriber}, State) ->
    subscriber_down_(Subscriber),
    {noreply, State};

handle_cast(Msg, State) ->
    ?UNEXPECTED_MSG(Msg, State).

handle_info({'DOWN', _MRef, process, DownPid, _Reason}, State = #state{submon = PM}) ->
    subscriber_down_(DownPid),
    {noreply, setstats(State#state{submon = PM:erase(DownPid)}), hibernate};

handle_info(Info, State) ->
    ?UNEXPECTED_INFO(Info, State).

terminate(_Reason, #state{pool = Pool, id = Id}) ->
    ?GPROC_POOL(leave, Pool, Id).

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%% Internal Functions
%%--------------------------------------------------------------------

do_subscribe(Topic, Subscriber, Options, State) ->
    case ets:lookup(mqtt_pubsub, {Topic, Subscriber}) of
        [] ->
            ?Dispatcher:async_subscribe(Topic, Subscriber),
            add_subscription(Subscriber, Topic),
            ets:insert(mqtt_pubsub, {{Topic, Subscriber}, Options}),
            {ok, monitor_subpid(Subscriber, State)};
        [_] ->
            {error, {already_subscribed, Topic}}
    end.

add_subscription(Subscriber, Topic) ->
    ets:insert(mqtt_subscription, {Subscriber, Topic}).

do_unsubscribe(Topic, Subscriber, State) ->
    case ets:lookup(mqtt_pubsub, {Topic, Subscriber}) of
        [_] ->
            ?Dispatcher:async_unsubscribe(Topic, Subscriber),
            del_subscription(Subscriber, Topic),
            ets:delete(mqtt_pubsub, {Topic, Subscriber}),
            {ok, case ets:member(mqtt_subscription, Subscriber) of
                true  -> State;
                false -> demonitor_subpid(Subscriber, State)
            end};
        [] ->
            {error, {subscription_not_found, Topic}}
    end.

del_subscription(Subscriber, Topic) ->
    ets:delete_object(mqtt_subscription, {Subscriber, Topic}).

subscriber_down_(Subscriber) ->
    lists:foreach(fun({_, Topic}) ->
                subscriber_down_(Subscriber, Topic)
        end, ets:lookup(mqtt_subscription, Subscriber)),
    ets:delete(mqtt_subscription, Subscriber).

subscriber_down_(DownPid, Topic) ->
    case ets:lookup(mqtt_pubsub, {Topic, DownPid}) of
        []  ->
            %% here?
            ?Dispatcher:async_unsubscribe(Topic, DownPid);
        [_] ->
            ?Dispatcher:async_unsubscribe(Topic, DownPid),
            ets:delete(mqtt_pubsub, {Topic, DownPid})
    end.

monitor_subpid(SubPid, State = #state{submon = PMon}) when is_pid(SubPid) ->
    State#state{submon = PMon:monitor(SubPid)};
monitor_subpid(_SubPid, State) ->
    State.

demonitor_subpid(SubPid, State = #state{submon = PMon}) when is_pid(SubPid) ->
    State#state{submon = PMon:demonitor(SubPid)};
demonitor_subpid(_SubPid, State) ->
    State.

setstats(State) when is_record(State, state) ->
    emqttd_stats:setstats('subscribers/count', 'subscribers/max', ets:info(mqtt_subscriber, size)),
    emqttd_stats:setstats('subscriptions/count', 'subscriptions/max', ets:info(mqtt_subscription, size)),
    State.

