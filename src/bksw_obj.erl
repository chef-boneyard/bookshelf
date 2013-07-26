%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Tim Dysinger <dysinger@opscode.com>
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

-module(bksw_obj).

-export([allowed_methods/2, content_types_accepted/2,
         content_types_provided/2, delete_resource/2, download/2,
         validate_content_checksum/2,
         finish_request/2,
         generate_etag/2, init/1, is_authorized/2, last_modified/2,
         service_available/2,
         resource_exists/2, upload/2]).

-include("bksw_obj.hrl").
-include_lib("webmachine/include/webmachine.hrl").
-include("internal.hrl").

%%===================================================================
%% Public API
%%===================================================================

init(Config) ->
    {ok, bksw_conf:get_context(Config)}.

%% By default, if wm sees a 'content-md5' header, it will read the request body to compute
%% the md5 and compare to the header value. A 400 will then be returned automagically by wm
%% if the digests do not match. Since we wish to read request bodies in a streaming fashion,
%% we need to handle our own checksum validation. Using wm's default would mean having a
%% full copy of the request body buffered into the request process state. So we define this
%% resource callback to blindly say the content is valid and then do the verification in the
%% upload/2 flow.
validate_content_checksum(Rq, Ctx) ->
    {true, Rq, Ctx}.

is_authorized(Rq, Ctx) ->
    bksw_sec:is_authorized(Rq, Ctx).

allowed_methods(Rq, Ctx) ->
    {['HEAD', 'GET', 'PUT', 'DELETE'], Rq, Ctx}.

content_types_provided(Rq, Ctx) ->
    CType =
    case wrq:get_req_header("accept", Rq) of
        undefined ->
            "application/octet-stream";
        "*/*" ->
            "application/octet-stream";
        C ->
            C
    end,
    {[{CType, download}], Rq, Ctx}.

content_types_accepted(Rq, Ctx) ->
    CT = case wrq:get_req_header("content-type", Rq) of
             undefined ->
                 "application/octet-stream";
             X ->
                 X
         end,
    {MT, _Params} = webmachine_util:media_type_to_detail(CT),
    {[{MT, upload}], Rq, Ctx}.

service_available(Req, Ctx) ->
    bksw_util:service_available(Req, Ctx).

resource_exists(Rq0, Ctx) ->
    {ok, Bucket, Path} = bksw_util:get_object_and_bucket(Rq0),
    %% Buckets always exist for writes since we create them on the fly
    case wrq:method(Rq0) of
        'PUT' ->
            {true, Rq0, Ctx};
        _ ->
            {bksw_io:entry_exists(Bucket, Path), Rq0, Ctx}
    end.

delete_resource(Rq0, Ctx) ->
    {ok, Bucket, Path} = bksw_util:get_object_and_bucket(Rq0),
    {bksw_io:entry_delete(Bucket, Path), Rq0, Ctx}.

last_modified(Rq0, Ctx) ->
    {ok, Bucket, Path} = bksw_util:get_object_and_bucket(Rq0),
    case bksw_io:entry_md(Bucket, Path) of
        {ok, #object{date = Date}} ->
            {Date, Rq0, Ctx};
        _ ->
            {halt, Rq0, Ctx}
    end.

generate_etag(Rq0, Ctx) ->
    {ok, Bucket, Path} = bksw_util:get_object_and_bucket(Rq0),
    case bksw_io:entry_md(Bucket, Path) of
        {ok, #object{digest = Digest}} ->
            {bksw_format:to_base64(Digest), Rq0, Ctx};
        _ ->
            {halt, Rq0, Ctx}
    end.

download(Rq0, Ctx) ->
    {ok, Bucket, Path} = bksw_util:get_object_and_bucket(Rq0),
    case bksw_io:open_for_read(Bucket, Path) of
        {ok, Ref} ->
            case bksw_conf:is_stream_download(Ctx) of
                true ->
                    {{stream, send_streamed_body(Ref)}, Rq0, Ctx};
                false ->
                    {fully_read(Ref, []), Rq0, Ctx}
            end;
        _Error ->
            {false, Rq0, Ctx}
    end.



%%===================================================================
%% Internal Functions
%%===================================================================
send_streamed_body(Ref) ->
     case bksw_io:read(Ref, ?BLOCK_SIZE) of
         {ok, eof} ->
            bksw_io:finish_read(Ref),
            {<<>>, done};
         {ok, Data} ->
             case byte_size(Data) < ?BLOCK_SIZE of
                 true ->
                     bksw_io:finish_read(Ref),
                     {Data, done};
                 false ->
                     {Data, fun() -> send_streamed_body(Ref) end}
             end;
        Error = {error, _} ->
             bksw_io:finish_read(Ref),
             error_logger:error_msg("Error occurred during content download: ~p~n", [Error]),
             Error
     end.

fully_read(Ref, Accum) ->
    case bksw_io:read(Ref, ?BLOCK_SIZE) of
        {ok, eof} ->
            lists:reverse(Accum);
        {ok, Data} ->
            fully_read(Ref, [Data|Accum]);
        Error ->
            error_logger:error_msg("Error occurred during content download: ~p~n", [Error]),
            lists:reverse(Accum)
    end.

upload(Rq0, Ctx) ->
    {ok, Bucket, Path} = bksw_util:get_object_and_bucket(Rq0),
    case bksw_io:open_for_write(Bucket, Path) of
        {ok, Ref} ->
            write_streamed_body(wrq:stream_req_body(Rq0, ?BLOCK_SIZE), Ref, Rq0, Ctx);
        Error ->
            error_logger:error_msg("Erroring opening ~p/~p for writing: ~p~n", [Bucket, Path, Error]),
            {false, Rq0, Ctx}
    end.

write_streamed_body({Data, done}, Ref, Rq0, Ctx) ->
    {ok, Ref1} = bksw_io:write(Ref, Data),
    {ok, Digest} = bksw_io:finish_write(Ref1),
    case get_header('Content-MD5', Rq0) of
        undefined ->
            Rq1 = bksw_req:with_etag(base64:encode(Digest), Rq0),
            {true, wrq:set_response_code(202, Rq1), Ctx};
        RawRequestMd5 ->
            RequestMd5 = base64:decode(RawRequestMd5),
            case RequestMd5 of
                Digest ->
                    Rq1 = bksw_req:with_etag(RawRequestMd5, Rq0),
                    {true, wrq:set_response_code(202, Rq1), Ctx};
                _ ->
                    {true, wrq:set_response_code(406, Rq0), Ctx}
            end
    end;
write_streamed_body({Data, Next}, Ref, Rq0, Ctx) ->
    {ok, Ref1} = bksw_io:write(Ref, Data),
    write_streamed_body(Next(), Ref1, Rq0, Ctx).

get_header(Header, Rq) ->
    wrq:get_req_header(Header, Rq).

finish_request(Rq0, Ctx) ->
    try
        case wrq:response_code(Rq0) of
            500 ->
                Rq1 = create_500_response(Rq0, Ctx),
                {true, Rq1, Ctx};
            _ ->
                {true, Rq0, Ctx}
        end
    catch
        X:Y ->
            error_logger:error_report({X, Y, erlang:get_stacktrace()})
    end.

create_500_response(Rq0, _Ctx) ->
    %% sanitize response body
    Msg = <<"internal service error">>,
    Rq1 = wrq:set_resp_header("Content-Type",
                               "text/plain", Rq0),
    wrq:set_resp_body(Msg, Rq1).
