%% -*- mode: Erlang; fill-column: 80; comment-column: 75; -*-
%%-------------------------------------------------------------------
%% @author Eric B Merritt <ericbmerritt@gmail.com>
%% Copyright 2012 Opscode, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

-module(bkswt_api_SUITE).

%% Note: This directive should only be used in test suites.
-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("../src/internal.hrl").

-define(STR_CHARS, "abcdefghijklmnopqrstuvwxyz").

%%====================================================================
%% TEST SERVER CALLBACK FUNCTIONS
%%====================================================================
init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(sec_fail, Config0) ->
    Config1 = init_per_testcase(not_sec_fail, Config0),
    AccessKeyID = random_string(10, "abcdefghijklmnopqrstuvwxyz"),
    SecretAccessKey = random_string(30, "abcdefghijklmnopqrstuvwxyz"),
    Port = 4321,
    S3State = mini_s3:new(AccessKeyID, SecretAccessKey,
                          lists:flatten(io_lib:format("http://127.0.0.1:~p",
                                                      [Port])),
                         path),
    lists:keyreplace(s3_conf, 1, Config1, {s3_conf, S3State});
init_per_testcase(upgrade_from_v0, Config) ->
    %% This fixes another rebar brokenness. We cant specify any options to
    %% common test in rebar
    Seed = now(),
    random:seed(Seed),
    error_logger:info_msg("Using random seed: ~p~n", [Seed]),
    Format0Data = filename:join([?config(data_dir, Config),
                                 "format_0_data"]),
    DiskStore = filename:join(proplists:get_value(priv_dir, Config),
                              random_string(10, "abcdefghijklmnopqrstuvwxyz")),
    LogDir = filename:join(proplists:get_value(priv_dir, Config),
                           "logs"),
    filelib:ensure_dir(filename:join(DiskStore, "tmp")),
    error_logger:info_msg("Using disk_store: ~p~n", [DiskStore]),
    CMD = ["cd ", Format0Data, "; tar cf - * | (cd ", DiskStore, "; tar xf -)"],
    error_logger:info_msg("copying format 0 data into disk store with command:~n~s~n",
                         [CMD]),
    os:cmd(CMD),
    AccessKeyID = random_string(10, "abcdefghijklmnopqrstuvwxyz"),
    SecretAccessKey = random_string(30, "abcdefghijklmnopqrstuvwxyz"),
    application:set_env(bookshelf, reqid_header_name, "X-Request-Id"),
    application:set_env(bookshelf, disk_store, DiskStore),
    application:set_env(bookshelf, keys, {AccessKeyID, SecretAccessKey}),
    application:set_env(bookshelf, log_dir, LogDir),
    application:set_env(bookshelf, stream_download, true),
    ok = bksw_app:manual_start(),
    %% force webmachine to pickup new dispatch_list. I don't understand why it
    %% isn't enough to do application:stop/start for webmachine, but it isn't.
    bksw_conf:reset_dispatch(),
    %% increase max sessions per server for ibrowse
    application:set_env(ibrowse, default_max_sessions, 256),
    %% disable request pipelining for ibrowse.
    application:set_env(ibrowse, default_max_pipeline_size, 1),
    Port = 4321,
    S3State = mini_s3:new(AccessKeyID, SecretAccessKey,
                          lists:flatten(io_lib:format("http://127.0.0.1:~p",
                                                      [Port])),
                          path),
    [{s3_conf, S3State}, {disk_store, DiskStore} | Config];
init_per_testcase(_TestCase, Config) ->
    %% This fixes another rebar brokenness. We cant specify any options to
    %% common test in rebar
    Seed = now(),
    random:seed(Seed),
    error_logger:info_msg("Using random seed: ~p~n", [Seed]),
    DiskStore = filename:join(proplists:get_value(priv_dir, Config),
                              random_string(10, "abcdefghijklmnopqrstuvwxyz")),
    LogDir = filename:join(proplists:get_value(priv_dir, Config),
                           "logs"),
    filelib:ensure_dir(filename:join(DiskStore, "tmp")),
    error_logger:info_msg("Using disk_store: ~p~n", [DiskStore]),
    AccessKeyID = random_string(10, "abcdefghijklmnopqrstuvwxyz"),
    SecretAccessKey = random_string(30, "abcdefghijklmnopqrstuvwxyz"),
    application:set_env(bookshelf, reqid_header_name, "X-Request-Id"),
    application:set_env(bookshelf, disk_store, DiskStore),
    application:set_env(bookshelf, keys, {AccessKeyID, SecretAccessKey}),
    application:set_env(bookshelf, log_dir, LogDir),
    application:set_env(bookshelf, stream_download, true),
    ok = bksw_app:manual_start(),
    %% force webmachine to pickup new dispatch_list. I don't understand why it
    %% isn't enough to do application:stop/start for webmachine, but it isn't.
    bksw_conf:reset_dispatch(),
    %% increase max sessions per server for ibrowse
    application:set_env(ibrowse, default_max_sessions, 256),
    %% disable request pipelining for ibrowse.
    application:set_env(ibrowse, default_max_pipeline_size, 1),
    Port = 4321,
    S3State = mini_s3:new(AccessKeyID, SecretAccessKey,
                          lists:flatten(io_lib:format("http://127.0.0.1:~p",
                                                      [Port])),
                          path),
    [{s3_conf, S3State}, {disk_store, DiskStore} | Config].

end_per_testcase(_TestCase, _Config) ->
    bksw_app:manual_stop(),
    ok.

all(doc) ->
    ["This test is runs the fs implementation of the bkss_store signature"].

all() ->
    [head_object,
     put_object,
     wi_basic,
     sec_fail,
     signed_url,
     signed_url_fail,
     at_the_same_time,
     upgrade_from_v0].

%%====================================================================
%% TEST CASES
%%====================================================================

wi_basic(doc) ->
    ["should be able to create, list & delete buckets"];
wi_basic(suite) ->
    [];
wi_basic(Config) when is_list(Config) ->
    {Timings, _} =
        timer:tc(fun() ->
                         S3Conf = proplists:get_value(s3_conf, Config),
                         %% Get much more then about 800 here and you start running out of file
                         %% descriptors on a normal box
                         Count = 50,
                         Buckets = [random_binary() || _ <- lists:seq(1, Count)],
                         Res = ec_plists:map(fun(B) ->
                                                     mini_s3:create_bucket(B, public_read_write, none, S3Conf)
                                             end,
                                             Buckets),
                         ?assert(lists:all(fun(Val) -> ok == Val end, Res)),
                         [{buckets, Details}] = mini_s3:list_buckets(S3Conf),
                         BucketNames = lists:map(fun(Opts) -> proplists:get_value(name, Opts) end,
                                                 Details),
                         ?assert(lists:all(fun(Name) -> lists:member(Name, BucketNames) end, Buckets)),
                         [DelBuck | _] = Buckets,
                         ?assertEqual(ok, mini_s3:delete_bucket(DelBuck, S3Conf)),
                         [{buckets, NewBuckets}] = mini_s3:list_buckets(S3Conf),
                         error_logger:info_msg("NewBuckets: ~p~n", [NewBuckets]),
                         ?assertEqual(Count - 1, length(NewBuckets)),

                         %% bucket name encoding should work
                         OddBucket = "a bucket",
                         OddBucketEnc = "a%20bucket",
                         mini_s3:create_bucket(OddBucketEnc, public_read_write, none, S3Conf),
                         Buckets1 = ?config(buckets, mini_s3:list_buckets(S3Conf)),
                         BucketNames1 = [ ?config(name, B) || B <- Buckets1 ],
                         error_logger:error_msg("Bucket Names:~n~p~n", [BucketNames1]),
                         ?assert(lists:member(OddBucket, BucketNames1)),
                         OddResult = mini_s3:list_objects(OddBucketEnc, [], S3Conf),
                         ?assertEqual("a bucket", ?config(name, OddResult)),
                         ?assertEqual([], ?config(contents, OddResult)),
                         mini_s3:delete_bucket(OddBucketEnc, S3Conf)
                 end),
    error_logger:info_msg("WI_BASIC TIMING ~p", [Timings]).


put_object(doc) ->
    ["should be able to put and list objects"];
put_object(suite) ->
    [];
put_object(Config) when is_list(Config) ->
    S3Conf = proplists:get_value(s3_conf, Config),
    Bucket = "bukkit",
    ?assertEqual(ok, mini_s3:create_bucket(Bucket, public_read_write, none, S3Conf)),
    BucketContents = mini_s3:list_objects(Bucket, [], S3Conf),
    ?assertEqual(Bucket, proplists:get_value(name, BucketContents)),
    ?assertEqual([], proplists:get_value(contents, BucketContents)),
    Count = 50,
    Objs = [filename:join(random_binary(), random_binary()) ||
               _ <- lists:seq(1,Count)],
    ec_plists:map(fun(F) ->
                          mini_s3:put_object(Bucket, F, F, [], [], S3Conf)
                  end, Objs),
    Result = mini_s3:list_objects(Bucket, [], S3Conf),
    ObjList = proplists:get_value(contents, Result),
    ?assertEqual(Count, length(ObjList)),
    ec_plists:map(fun(Obj) ->
                          Key = proplists:get_value(key, Obj),
                          ObjDetail = mini_s3:get_object(Bucket, Key, [], S3Conf),
                          ?assertMatch(Key,
                                       erlang:binary_to_list(proplists:get_value(content, ObjDetail)))
                  end, ObjList).

head_object(doc) ->
    ["supports HEAD operations with PUT"];
head_object(suite) ->
    [];
head_object(Config) when is_list(Config) ->
    S3Conf = proplists:get_value(s3_conf, Config),
    Bucket = "head-put-tests",
    ?assertEqual(ok, mini_s3:create_bucket(Bucket, public_read_write, none, S3Conf)),
    BucketContents = mini_s3:list_objects(Bucket, [], S3Conf),
    ?assertEqual(Bucket, proplists:get_value(name, BucketContents)),
    ?assertEqual([], proplists:get_value(contents, BucketContents)),
    Count = 50,
    Objs = [filename:join(random_binary(), random_binary()) ||
               _ <- lists:seq(1,Count)],
    ec_plists:map(fun(F) ->
                          mini_s3:put_object(Bucket, F, F, [], [], S3Conf)
                  end, Objs),
    Got = ec_plists:ftmap(fun(Obj) ->
                                  mini_s3:get_object_metadata(Bucket, Obj, [], S3Conf)
                          end, Objs, 10000),
    error_logger:info_msg("Got: ~p~n", [Got]),
    [ ?assertMatch({value, _}, Item) || Item <- Got ],
    %% verify 404 behavior
    V = try
            mini_s3:get_object_metadata(Bucket, "no-such-object", [], S3Conf)
        catch
            error:Why ->
                Why
        end,
    ct:pal("HEAD 404: ~p", [V]).


sec_fail(doc) ->
    ["Check authentication failure on the part of the caller"];
sec_fail(suite) ->
    [];
sec_fail(Config) when is_list(Config) ->
    S3Conf = proplists:get_value(s3_conf, Config),
    Bucket = random_binary(),
    ?assertError({aws_error, {http_error, 403, _}},
                 mini_s3:create_bucket(Bucket, public_read_write, none, S3Conf)),
    %% also verify that unsigned URL requests don't crash
    {ok, Status, _H, Body} = ibrowse:send_req("http://127.0.0.1:4321/foobar", [],
                                              get),
    ?assertEqual("403", Status),
    ?assert(string:str(Body, "<Message>Access Denied</Message>") > 0).

signed_url(doc) ->
    ["Test that signed urls actually work"];
signed_url(suite) ->
    [];
signed_url(Config) when is_list(Config) ->
    S3Conf = proplists:get_value(s3_conf, Config),
    Bucket = random_binary(),
    mini_s3:create_bucket(Bucket, public_read_write, none, S3Conf),
    Content = "<x>Super Foo</x>",
    Headers = [{"content-type", "text/xml"},
               {"content-md5",
                erlang:binary_to_list(base64:encode(crypto:md5(Content)))}],
    SignedUrl = mini_s3:s3_url('put', Bucket, "foo", 1000,
                               Headers,
                               S3Conf),
    Response = httpc:request(put, {erlang:binary_to_list(SignedUrl),
                                   Headers,
                                   "text/xml", Content}, [], []),
    ?assertMatch({ok, _}, Response),
    Response2 = httpc:request(put, {erlang:binary_to_list(SignedUrl),
                                   [{"content-type", "text/xml"},
                                    {"content-md5",
                                     erlang:binary_to_list(base64:encode(
                                                             crypto:md5("Something Else")))}],
                                    "text/xml", Content}, [], []),
  ?assertMatch({ok,{{"HTTP/1.1",403,"Forbidden"}, _, _}},
               Response2).

signed_url_fail(doc) ->
    ["Test that signed url expiration actually works"];
signed_url_fail(suite) ->
    [];
signed_url_fail(Config) when is_list(Config) ->
    S3Conf = proplists:get_value(s3_conf, Config),
    Bucket = random_binary(),
    mini_s3:create_bucket(Bucket, public_read_write, none, S3Conf),
    Content = "<x>Super Foo</x>",
    Headers = [{"content-type", "text/xml"},
               {"content-md5",
                erlang:binary_to_list(base64:encode(crypto:md5(Content)))}],
    SignedUrl = mini_s3:s3_url('put', Bucket, "foo", -1,
                               Headers,
                               S3Conf),
    Response = httpc:request(put, {erlang:binary_to_list(SignedUrl),
                                   Headers,
                                   "text/xml", Content}, [], []),
    ?assertMatch({ok,{{"HTTP/1.1",403,"Forbidden"}, _, _}},
                 Response).

at_the_same_time(doc) ->
    ["should handle concurrent reads and writes"];
at_the_same_time(suite) -> [];
at_the_same_time(Config) when is_list(Config) ->
    S3Conf = proplists:get_value(s3_conf, Config),
    Bucket = "bukkit",
    ?assertEqual(ok, mini_s3:create_bucket(Bucket, public_read_write, none, S3Conf)),
    BucketContents = mini_s3:list_objects(Bucket, [], S3Conf),
    ?assertEqual(Bucket, proplists:get_value(name, BucketContents)),
    ?assertEqual([], proplists:get_value(contents, BucketContents)),
    Count = 100,
    BigData = list_to_binary(lists:duplicate(2000000, 2)),
    Key = filename:join(random_binary(), random_binary()),
    error_logger:info_report({at_the_same_time, key, Key}),
    mini_s3:put_object(Bucket, Key, BigData, [], [], S3Conf),
    DoOp = fun(read) ->
                   Res = mini_s3:get_object(Bucket, Key, [], S3Conf),
                   ResContent = proplists:get_value(content, Res),
                   ?assertEqual(BigData, ResContent),
                   ok;
              (write) ->
                   mini_s3:put_object(Bucket, Key, BigData, [], [], S3Conf),
                   ok
           end,
    Ops = lists:flatten([[write, read] || _ <- lists:seq(1, Count)]),
    Results = ec_plists:map(fun(O) -> DoOp(O) end, Ops),
    ?assertEqual([ ok || _ <- lists:seq(1, 2 * Count)], Results),
    error_logger:info_msg("done with plists map of ops"),
    Result = mini_s3:list_objects(Bucket, [], S3Conf),
    ObjList = proplists:get_value(contents, Result),
    ?assertEqual(1, length(ObjList)).

upgrade_from_v0(doc) ->
    ["Upgrades from version 0 disk format to current version"];
upgrade_from_v0(suite) -> [];
upgrade_from_v0(Config) ->
    ShouldExist = [
                   {"bucket-1", "xjbrpodcionabrzhikgliowdzvbvbc/kqvfgzhnlkizzvbidsxwavrktxcasx"},
                   {"bucket-1", "zrcsghibdgwjghkqsdajycrjwitntu/ahnsvorjeauuwusthkdunsslzffkfn"},
                   {"bucket-2", "drniwxjwkasvovjjoafthnoqgtlung/lhfivdpsosyjybnmfpxkgplycrclmz"},
                   {"bucket-2", "nbmxbspdkbubastgtzzkhtunqznkcg/afbtmzfyyftrdxfbnmkslckewisxns"},
                   {"bucket%20space", "xjbrpodcionabrzhikgliowdzvbvbc/kqvfgzhnlkizzvbidsxwavrktxcasx"}
                  ],

    S3Conf = ?config(s3_conf, Config),

    AssertCount = fun(Bucket, Count) ->
                           Res = mini_s3:list_objects(Bucket, [], S3Conf),
                           Contents = proplists:get_value(contents, Res),
                           ?assertEqual(Count, length(Contents))
                   end,

    AssertCount("bucket-1", 2),
    AssertCount("bucket-2", 45),
    AssertCount("bucket-3", 1),
    AssertCount("bucket-4", 0),
    AssertCount("bucket%20space", 2),

    [ begin
          Res = mini_s3:get_object(Bucket, Key, [], S3Conf),
          ct:pal("Found: ~p~n", [Res])
      end || {Bucket, Key} <- ShouldExist ],

    ok.


%%====================================================================
%% Utility Functions
%%====================================================================
random_binary() ->
    random_string(30, ?STR_CHARS).

random_string(Length, AllowedChars) ->
    lists:foldl(fun(_, Acc) ->
                        [lists:nth(random:uniform(length(AllowedChars)),
                                   AllowedChars) | Acc]
                end, [], lists:seq(1, Length)).
