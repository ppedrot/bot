let port = try "PORT" |> Sys.getenv |> int_of_string with Not_found -> 8000

let username = Sys.getenv "USERNAME"

let password = Sys.getenv "PASSWORD"

let credentials = `Basic (username, password)

let gitlab_access_token = Sys.getenv "GITLAB_ACCESS_TOKEN"

let gitlab_header = [("PRIVATE-TOKEN", gitlab_access_token)]

let github_access_token = Sys.getenv "GITHUB_ACCESS_TOKEN"

let project_api_preview_header =
  [("Accept", "application/vnd.github.inertia-preview+json")]

open Base
open Bot_components
open Cohttp
open Cohttp_lwt_unix
open Lwt
open Utils

let gitlab_repo = f "https://%s:%s@gitlab.com/%s/%s.git" username password

let report_status command report code =
  f "Command \"%s\" %s %d" command report code |> print_endline

let ( |&& ) command1 command2 = command1 ^ " && " ^ command2

let execute_cmd command =
  Lwt_unix.system command
  >|= fun status ->
  match status with
  | Unix.WEXITED code ->
      report_status command "exited with status" code ;
      if Int.equal code 0 then true else false
  | Unix.WSIGNALED signal ->
      report_status command "was killed by signal number" signal ;
      false
  | Unix.WSTOPPED signal ->
      report_status command "was stopped by signal number" signal ;
      false

let git_fetch ?(force = true) repo remote_ref local_branch_name =
  f "git fetch -fu %s %s%s:refs/heads/%s" repo
    (if force then "+" else "")
    remote_ref local_branch_name

let git_push ?(force = true) repo local_ref remote_branch_name =
  f "git push %s %s%s:refs/heads/%s" repo
    (if force then " +" else " ")
    local_ref remote_branch_name

let git_delete repo remote_branch_name =
  git_push ~force:false repo "" remote_branch_name

let git_make_ancestor ~base ref2 = f "./make_ancestor.sh %s %s" base ref2

let extract_commit json =
  let open Yojson.Basic.Util in
  let commit_json = json |> member "commit" in
  let message = commit_json |> member "message" |> to_string in
  if string_match ~regexp:"Bot merge .* into \\(.*\\)" message then
    Str.matched_group 1 message
  else
    (* In the case of build webhooks, the id is a number and the sha is the
       reference of the commit, while in the case of pipeline hooks only id
       is present and represents the sha. *)
    ( match commit_json |> member "sha" with
    | `Null -> commit_json |> member "id"
    | sha -> sha )
    |> to_string

let print_response (resp, body) =
  let code = resp |> Response.status |> Code.code_of_status in
  print_string "Response code: " ;
  print_int code ;
  print_newline () ;
  if code < 200 && code > 299 then (
    print_string "Headers: " ;
    resp |> Response.headers |> Header.to_string |> print_endline ;
    body |> Cohttp_lwt.Body.to_string
    >|= fun body -> print_endline "Body:" ; print_endline body )
  else return ()

let headers header_list =
  Header.init ()
  |> (fun headers -> Header.add_list headers header_list)
  |> (fun headers -> Header.add headers "User-Agent" "coqbot")
  |> fun headers -> Header.add_authorization headers credentials

let send_request ~body ~uri header_list =
  let headers = headers header_list in
  print_endline "Sending request." ;
  Client.post ~body ~headers uri >>= print_response

let add_rebase_label (issue : GitHub_subscriptions.issue) =
  let body = Cohttp_lwt.Body.of_string "[ \"needs: rebase\" ]" in
  let uri =
    f "https://api.github.com/repos/%s/%s/issues/%d/labels" issue.owner
      issue.repo issue.number
    |> (fun url -> print_string "URL: " ; print_endline url ; url)
    |> Uri.of_string
  in
  send_request ~body ~uri []

let remove_rebase_label (issue : GitHub_subscriptions.issue) =
  let headers = headers [] in
  let uri =
    f "https://api.github.com/repos/%s/%s/issues/%d/labels/needs%%3A rebase"
      issue.owner issue.repo issue.number
    |> (fun url -> print_string "URL: " ; print_endline url ; url)
    |> Uri.of_string
  in
  print_endline "Sending delete request." ;
  Client.delete ~headers uri >>= print_response

let update_milestone new_milestone (issue : GitHub_subscriptions.issue) =
  let headers = headers [] in
  let uri =
    f "https://api.github.com/repos/%s/%s/issues/%d" issue.owner issue.repo
      issue.number
    |> (fun url -> print_string "URL: " ; print_endline url ; url)
    |> Uri.of_string
  in
  let body =
    "{\"milestone\": " ^ new_milestone ^ "}" |> Cohttp_lwt.Body.of_string
  in
  print_endline "Sending patch request." ;
  Client.patch ~headers ~body uri >>= print_response

let remove_milestone = update_milestone "null"

let add_pr_to_column pr_id column_id =
  let body =
    "{\"content_id\":" ^ Int.to_string pr_id
    ^ ", \"content_type\": \"PullRequest\"}"
    |> (fun body -> print_endline "Body:" ; print_endline body ; body)
    |> Cohttp_lwt.Body.of_string
  in
  let uri =
    "https://api.github.com/projects/columns/" ^ Int.to_string column_id
    ^ "/cards"
    |> (fun url -> print_string "URL: " ; print_endline url ; url)
    |> Uri.of_string
  in
  send_request ~body ~uri project_api_preview_header

let send_status_check ~repo_full_name ~commit ~state ~url ~context ~description
    =
  let body =
    "{\"state\": \"" ^ state ^ "\",\"target_url\":\"" ^ url
    ^ "\", \"description\": \"" ^ description ^ "\", \"context\": \"" ^ context
    ^ "\"}"
    |> (fun body -> print_endline "Body:" ; print_endline body ; body)
    |> Cohttp_lwt.Body.of_string
  in
  let uri =
    "https://api.github.com/repos/" ^ repo_full_name ^ "/statuses/" ^ commit
    |> (fun url -> print_string "URL: " ; print_endline url ; url)
    |> Uri.of_string
  in
  send_request ~body ~uri []

let retry_job ~project_id ~build_id =
  let uri =
    "https://gitlab.com/api/v4/projects/" ^ Int.to_string project_id ^ "/jobs/"
    ^ Int.to_string build_id ^ "/retry"
    |> (fun url -> print_string "URL: " ; print_endline url ; url)
    |> Uri.of_string
  in
  send_request ~body:Cohttp_lwt.Body.empty ~uri gitlab_header

let handle_json action default body =
  try
    let json = Yojson.Basic.from_string body in
    (* print_endline "JSON decoded."; *)
    action json
  with
  | Yojson.Json_error err ->
      prerr_string "Json error: " ;
      prerr_endline err ;
      default
  | Yojson.Basic.Util.Type_error (err, _) ->
      prerr_string "Json type error: " ;
      prerr_endline err ;
      default

let generic_get relative_uri ?(header_list = []) ~default json_handler =
  let uri = "https://api.github.com/" ^ relative_uri |> Uri.of_string in
  let headers = headers header_list in
  Client.get ~headers uri
  >>= (fun (response, body) -> Cohttp_lwt.Body.to_string body)
  >|= handle_json json_handler default

let get_pull_request_info pr_number =
  GitHub_queries.pull_request_id_db_id_and_milestone ~token:github_access_token
    ~owner:"coq" ~repo:"coq" ~number:pr_number ()
  >|= function
  | Ok result -> (
    match result#repository with
    | Some repo -> (
      match repo#pullRequest with
      | Some pr -> (
        match (pr#databaseId, pr#milestone) with
        | Some db_id, Some milestone -> (
          match milestone#description with
          | Some description -> (
            match
              GitHub_queries.Milestone.get_backport_info "coqbot" description
            with
            | Some bp_info -> Some (pr#id, db_id, bp_info)
            | _ -> None )
          | _ -> None )
        | _ -> None )
      | _ -> None )
    | _ -> None )
  | _ -> None

let get_status_check ~repo_full_name ~commit ~build_name =
  generic_get
    (Printf.sprintf "repos/%s/commits/%s/statuses" repo_full_name commit)
    ~default:false (fun json ->
      let open Yojson.Basic.Util in
      json |> to_list
      |> List.exists ~f:(fun json ->
             json |> member "context" |> to_string |> String.equal build_name
         ) )

let get_cards_in_column column_id =
  generic_get
    ("projects/columns/" ^ Int.to_string column_id ^ "/cards")
    ~header_list:project_api_preview_header ~default:[]
    (fun json ->
      let open Yojson.Basic.Util in
      json |> to_list
      |> List.filter_map ~f:(fun json ->
             let card_id = json |> member "id" |> to_int in
             let content_url =
               json |> member "content_url" |> to_string_option
               |> Option.value ~default:""
             in
             let regexp = "https://api.github.com/repos/.*/\\([0-9]*\\)" in
             if string_match ~regexp content_url then
               let pr_number = Str.matched_group 1 content_url in
               Some (pr_number, card_id)
             else None ) )

let pull_request_updated (pr_info : GitHub_subscriptions.pull_request_info) ()
    =
  let pr_local_branch = f "pr-%d" pr_info.issue.issue.number in
  let gitlab_repo =
    gitlab_repo pr_info.issue.issue.owner pr_info.issue.issue.repo
  in
  let pr_local_base_branch = f "remote-%s" pr_info.base.branch.name in
  print_endline "Action warrants fetch / push." ;
  git_fetch pr_info.base.branch.repo_url pr_info.base.branch.name
    pr_local_base_branch
  |&& git_fetch pr_info.head.branch.repo_url pr_info.head.branch.name
        pr_local_branch
  |&& git_make_ancestor ~base:pr_local_base_branch pr_local_branch
  |> execute_cmd
  >>= fun ok ->
  if ok then
    (* Remove rebase label *)
    ( if pr_info.issue.labels |> List.exists ~f:(String.equal "needs: rebase")
    then (
      print_endline "Removing the rebase label." ;
      remove_rebase_label pr_info.issue.issue )
    else return () )
    <&> (* Force push *)
    ( git_push gitlab_repo pr_local_branch pr_local_branch
    |> execute_cmd >|= ignore )
  else (
    print_endline "Adding the rebase label and a failed status check." ;
    add_rebase_label pr_info.issue.issue
    <&> send_status_check
          ~repo_full_name:
            (f "%s/%s" pr_info.issue.issue.owner pr_info.issue.issue.repo)
          ~commit:pr_info.head.sha ~state:"error" ~url:""
          ~context:"GitLab CI pipeline"
          ~description:
            "Pipeline did not run on GitLab CI because PR has conflicts with \
             base branch." )

let pull_request_closed (pr_info : GitHub_subscriptions.pull_request_info) () =
  let pr_local_branch = f "pr-%d" pr_info.issue.issue.number in
  let gitlab_repo =
    gitlab_repo pr_info.issue.issue.owner pr_info.issue.issue.repo
  in
  git_delete gitlab_repo pr_local_branch
  |> execute_cmd >|= ignore
  <&>
  if not pr_info.merged then (
    print_endline "PR was closed without getting merged: remove the milestone." ;
    remove_milestone pr_info.issue.issue )
  else
    (* TODO: if PR was merged in master without a milestone, post an alert *)
    return ()

let project_action ~(issue : GitHub_subscriptions.issue) ~column_id () =
  get_pull_request_info issue.number
  >>= function
  | None ->
      print_endline "Could not find backporting info for PR." ;
      return ()
  | Some (id, _, {request_inclusion_column; rejected_milestone})
    when Int.equal request_inclusion_column column_id ->
      print_endline "This was a request inclusion column: PR was rejected." ;
      print_endline "Change of milestone requested to:" ;
      print_endline rejected_milestone ;
      update_milestone rejected_milestone issue
      <&> GitHub_mutations.post_comment ~token:github_access_token ~id
            ~message:
              "This PR was postponed. Please update accordingly the milestone \
               of any issue that this fixes as this cannot be done \
               automatically."
  | _ ->
      print_endline "This was not a request inclusion column: ignoring." ;
      return ()

let push_action json =
  print_endline "Merge and backport commit messages:" ;
  let open Yojson.Basic.Util in
  let base_ref = json |> member "ref" |> to_string in
  let commit_action commit =
    let commit_msg = commit |> member "message" |> to_string in
    if string_match ~regexp:"Merge PR #\\([0-9]*\\):" commit_msg then (
      print_endline commit_msg ;
      let pr_number = Str.matched_group 1 commit_msg |> Int.of_string in
      print_string "PR #" ;
      print_int pr_number ;
      print_endline " was merged." ;
      get_pull_request_info pr_number
      >>= fun pr_info ->
      match pr_info with
      | Some
          (_, pr_id, {backport_to; request_inclusion_column; backported_column})
        ->
          if "refs/heads/" ^ backport_to |> String.equal base_ref then (
            print_endline "PR was merged into the backportig branch directly." ;
            add_pr_to_column pr_id backported_column )
          else (
            print_endline (f "Backporting to %s was requested." backport_to) ;
            add_pr_to_column pr_id request_inclusion_column )
      | None ->
          print_endline "Did not get any backporting info." ;
          return () )
    else if string_match ~regexp:"Backport PR #\\([0-9]*\\):" commit_msg then (
      print_endline commit_msg ;
      let pr_number = Str.matched_group 1 commit_msg in
      print_string "PR #" ;
      print_string pr_number ;
      print_endline " was backported." ;
      GitHub_queries.backported_pr_info ~token:github_access_token
        (Int.of_string pr_number) base_ref
      >>= function
      | Some ({card_id; column_id} as input) ->
          print_string "Moving card " ;
          print_string card_id ;
          print_string " to column " ;
          print_string column_id ;
          print_newline () ;
          GitHub_mutations.mv_card_to_column ~token:github_access_token input
      | None ->
          prerr_endline "Could not find backporting info for backported PR." ;
          return () )
    else return ()
  in
  (fun () ->
    json |> member "commits" |> to_list |> Lwt_list.iter_s commit_action )
  |> Lwt.async

let get_build_trace ~project_id ~build_id =
  let uri =
    "https://gitlab.com/api/v4/projects/" ^ Int.to_string project_id ^ "/jobs/"
    ^ Int.to_string build_id ^ "/trace"
    |> Uri.of_string
  in
  let headers = headers gitlab_header in
  Client.get ~headers uri
  >>= fun (_response, body) -> Cohttp_lwt.Body.to_string body

let repeat_request request =
  let rec aux t =
    request
    >>= fun body ->
    if String.is_empty body then Lwt_unix.sleep t >>= fun () -> aux (t *. 2.)
    else return body
  in
  aux 2.

type build_failure = Warn | Retry | Ignore

let trace_action ~repo_full_name trace =
  let trace_size = String.length trace in
  print_string "Trace size: " ;
  print_int trace_size ;
  print_newline () ;
  let test regexp = string_match ~regexp trace in
  if test "Job failed: exit code 137" then (
    print_endline "Exit code 137. Retrying..." ;
    Retry )
  else if test "Job failed: exit status 255" then (
    print_endline "Exit status 255. Retrying..." ;
    Retry )
  else if test "Job failed (system failure)" then (
    print_endline "System failure. Retrying..." ;
    Retry )
  else if
    ( test "Uploading artifacts to coordinator... failed"
    || test "Uploading artifacts to coordinator... error" )
    && not (test "Uploading artifacts to coordinator... ok")
  then (
    print_endline "Artifact uploading failure. Retrying..." ;
    Retry )
  else if
    test "ERROR: Downloading artifacts from coordinator... error"
    && test "request canceled (Client.Timeout exceeded while reading body)"
    && test "FATAL: invalid argument"
  then (
    print_endline "Artifact downloading failure. Retrying..." ;
    Retry )
  else if
    test "transfer closed with outstanding read data remaining"
    || test "HTTP request sent, awaiting response... 50[0-9]"
    || test "The requested URL returned error: 502"
    || test "The remote end hung up unexpectedly"
    || test "error: unable to download 'https://cache.nixos.org/"
  then (
    print_endline "Connectivity issue. Retrying..." ;
    Retry )
  else if test "fatal: reference is not a tree" then (
    print_endline "Normal failure: reference is not a tree." ;
    Ignore )
  else if
    String.equal repo_full_name "coq/coq"
    && test "Error response from daemon: manifest for .* not found"
  then (
    print_endline "Docker image not found. Do not report anything specific." ;
    Ignore )
  else Warn

let job_action json =
  let open Yojson.Basic.Util in
  let build_status = json |> member "build_status" |> to_string in
  let build_id = json |> member "build_id" |> to_int in
  let build_name = json |> member "build_name" |> to_string in
  let commit = json |> extract_commit in
  let repo_full_name =
    json |> member "project_name" |> to_string
    |> Str.global_replace (Str.regexp " ") ""
  in
  let send_url (kind, url) =
    (fun () ->
      let context = Printf.sprintf "%s: %s artifact" build_name kind in
      let description_base = Printf.sprintf "Link to %s build artifact" kind in
      url |> Uri.of_string |> Client.get
      >>= fun (resp, _) ->
      if resp |> Response.status |> Code.code_of_status |> Int.equal 200 then
        send_status_check ~repo_full_name ~commit ~state:"success" ~url
          ~context ~description:(description_base ^ ".")
      else (
        print_endline "But we didn't get a 200 code when checking the URL." ;
        send_status_check ~repo_full_name ~commit ~state:"failure"
          ~url:
            (Printf.sprintf "https://gitlab.com/%s/-/jobs/%d" repo_full_name
               build_id)
          ~context
          ~description:(description_base ^ ": not found.") ) )
    |> Lwt.async
  in
  if String.equal build_status "failed" then (
    let project_id = json |> member "project_id" |> to_int in
    let failure_reason = json |> member "build_failure_reason" |> to_string in
    let allow_fail = json |> member "build_allow_failure" |> to_bool in
    let send_status_check () =
      if allow_fail then (
        print_endline "Job is allowed to fail." ;
        return () )
      else (
        print_endline "Pushing a status check..." ;
        send_status_check ~repo_full_name ~commit ~state:"failure"
          ~url:
            (Printf.sprintf "https://gitlab.com/%s/-/jobs/%d" repo_full_name
               build_id)
          ~context:build_name
          ~description:(failure_reason ^ " on GitLab CI") )
    in
    print_string "Failed job " ;
    print_int build_id ;
    print_string " of project " ;
    print_int project_id ;
    print_endline "." ;
    print_string "Failure reason: " ;
    print_endline failure_reason ;
    (fun () ->
      if String.equal failure_reason "runner_system_failure" then (
        print_endline "Runner failure reported by GitLab CI. Retrying..." ;
        retry_job ~project_id ~build_id )
      else if String.equal failure_reason "stuck_or_timeout_failure" then (
        print_endline "Timeout reported by GitLab CI." ;
        send_status_check () )
      else if String.equal failure_reason "script_failure" then (
        print_endline
          "GitLab CI reports a script failure but it could be something else. \
           Checking the trace..." ;
        repeat_request (get_build_trace ~project_id ~build_id)
        >|= trace_action ~repo_full_name
        >>= function
        | Warn ->
            print_endline "Actual failure." ;
            send_status_check ()
        | Retry -> retry_job ~project_id ~build_id
        | Ignore -> return () )
      else (
        print_endline "Unusual error." ;
        send_status_check () ) )
    |> Lwt.async )
  else if String.equal build_status "success" then (
    (fun () ->
      get_status_check ~repo_full_name ~commit ~build_name
      >>= fun b ->
      if b then (
        print_endline
          "There existed a previous status check for this build, we'll \
           override it." ;
        send_status_check ~repo_full_name ~commit ~state:"success"
          ~url:
            (Printf.sprintf "https://gitlab.com/%s/-/jobs/%d" repo_full_name
               build_id)
          ~context:build_name
          ~description:"Test succeeded on GitLab CI after being retried" )
      else return () )
    |> Lwt.async ;
    if String.equal build_name "doc:refman" then (
      print_endline
        "This is a successful refman build. Pushing a status check with a \
         link..." ;
      let url_base =
        Printf.sprintf
          "https://coq.gitlab.io/-/coq/-/jobs/%d/artifacts/_install_ci/share/doc/coq"
          build_id
      in
      [ ("refman", Printf.sprintf "%s/sphinx/html/index.html" url_base)
      ; ("stdlib", Printf.sprintf "%s/html/stdlib/index.html" url_base) ]
      |> List.iter ~f:send_url )
    else if String.equal build_name "doc:ml-api:odoc" then (
      print_endline
        "This is a successful ml-api build. Pushing a status check with a \
         link..." ;
      ( "ml-api"
      , Printf.sprintf
          "https://coq.gitlab.io/-/coq/-/jobs/%d/artifacts/_build/default/_doc/_html/index.html"
          build_id )
      |> send_url ) )

let pipeline_action json =
  let open Yojson.Basic.Util in
  let pipeline_json = json |> member "object_attributes" in
  let state = pipeline_json |> member "status" |> to_string in
  let id = pipeline_json |> member "id" |> to_int in
  let commit = json |> extract_commit in
  let repo_full_name =
    json |> member "project" |> member "path_with_namespace" |> to_string
  in
  match state with
  | "skipped" -> ()
  | _ ->
      let state, description =
        match state with
        | "success" -> ("success", "Pipeline completed on GitLab CI")
        | "pending" -> ("pending", "Pipeline is pending on GitLab CI")
        | "running" -> ("pending", "Pipeline is running on GitLab CI")
        | "failed" -> ("failure", "Pipeline completed with errors on GitLab CI")
        | "cancelled" -> ("error", "Pipeline was cancelled on GitLab CI")
        | _ -> ("error", "Unknown pipeline status: " ^ state)
      in
      (fun () ->
        send_status_check ~repo_full_name ~commit ~state
          ~url:
            (Printf.sprintf "https://gitlab.com/%s/pipelines/%d" repo_full_name
               id)
          ~context:"GitLab CI pipeline" ~description )
      |> Lwt.async

let owner_team_map =
  Map.of_alist_exn
    (module String)
    [("martijnbastiaan-test-org", "martijnbastiaan-test-team")]

let callback _conn req body =
  let body = Cohttp_lwt.Body.to_string body in
  (* print_endline "Request received."; *)
  let handle_request action =
    (fun () -> body >|= handle_json action ()) |> Lwt.async ;
    Server.respond_string ~status:`OK ~body:"" ()
  in
  match Uri.path (Request.uri req) with
  | "/job" -> handle_request job_action
  | "/pipeline" -> handle_request pipeline_action
  | "/push" -> handle_request push_action
  | "/pull_request" | "/github" -> (
      body
      >>= fun body ->
      match GitHub_subscriptions.receive_github (Request.headers req) body with
      | Ok (GitHub_subscriptions.PullRequestUpdated pr_info) -> (
        match Map.find owner_team_map pr_info.issue.issue.owner with
        | Some team ->
            (fun () ->
              GitHub_queries.get_team_membership ~token:github_access_token
                ~org:pr_info.issue.issue.owner ~team ~user:pr_info.issue.user
              >>= function
              | Ok true ->
                  print_endline "Authorized user: pushing to GitLab." ;
                  pull_request_updated pr_info ()
              | Ok false -> Lwt_io.print "Unauthorized user: doing nothing.\n"
              | Error err -> Lwt_io.printf "Error: %s\n" err )
            |> Lwt.async ;
            Server.respond_string ~status:`OK
              ~body:
                (f
                   "Pull request was (re)opened / updated. Checking that user \
                    %s is a member of @%s/%s before pushing to GitLab."
                   pr_info.issue.user pr_info.issue.issue.owner team)
              ()
        | None ->
            pull_request_updated pr_info |> Lwt.async ;
            Server.respond_string ~status:`OK
              ~body:
                (f
                   "Pull request %s/%s#%d was (re)opened / updated: \
                    (force-)pushing to GitLab."
                   pr_info.issue.issue.owner pr_info.issue.issue.repo
                   pr_info.issue.issue.number)
              () )
      | Ok (GitHub_subscriptions.PullRequestClosed pr_info) ->
          pull_request_closed pr_info |> Lwt.async ;
          Server.respond_string ~status:`OK
            ~body:
              (f
                 "Pull request %s/%s#%d was closed: removing the branch from \
                  GitLab."
                 pr_info.issue.issue.owner pr_info.issue.issue.repo
                 pr_info.issue.issue.number)
            ()
      | Ok (GitHub_subscriptions.IssueClosed {issue}) ->
          (fun () ->
            GitHub_queries.get_issue_closer_info ~token:github_access_token
              issue
            >>= function
            | Ok result ->
                GitHub_mutations.reflect_pull_request_milestone
                  ~token:github_access_token result
            | Error err -> Lwt_io.print (f "Error: %s\n" err) )
          |> Lwt.async ;
          Server.respond_string ~status:`OK
            ~body:
              (f "Issue %s/%s#%d was closed: checking its milestone."
                 issue.owner issue.repo issue.number)
            ()
      | Ok
          (GitHub_subscriptions.RemovedFromProject
            ({issue= Some issue; column_id} as card)) ->
          project_action ~issue ~column_id |> Lwt.async ;
          Server.respond_string ~status:`OK
            ~body:
              (f
                 "Issue or PR %s/%s#%d was removed from project column %d: \
                  checking if this was a backporting column."
                 issue.owner issue.repo issue.number card.column_id)
            ()
      | Ok (GitHub_subscriptions.RemovedFromProject _) ->
          Server.respond_string ~status:`OK
            ~body:"Note card removed from project: nothing to do." ()
      | Ok (GitHub_subscriptions.CommentCreated {issue= {pull_request= false}})
        ->
          Server.respond_string ~status:`OK
            ~body:"Issue comment: nothing to do." ()
      | Ok (GitHub_subscriptions.CommentCreated comment_info)
        when string_match ~regexp:"@coqbot: [Rr]un CI now" comment_info.body ->
          (fun () ->
            match Map.find owner_team_map comment_info.issue.issue.owner with
            | None ->
                Lwt_io.printf
                  "Could not find %s in our list of organizations.\n"
                  comment_info.issue.issue.owner
            | Some team -> (
                GitHub_queries.get_team_membership ~token:github_access_token
                  ~org:comment_info.issue.issue.owner ~team
                  ~user:comment_info.issue.user
                >>= function
                | Ok false ->
                    Lwt_io.print "Unauthorized user: doing nothing.\n"
                | Error err -> Lwt_io.printf "Error: %s\n" err
                | Ok true -> (
                    print_endline "Authorized user: pushing to GitLab." ;
                    match comment_info.pull_request with
                    | Some pr_info -> pull_request_updated pr_info ()
                    | None -> (
                        GitHub_queries.get_pull_request_info
                          ~token:github_access_token comment_info.issue
                        >>= function
                        | Ok pr_info -> pull_request_updated pr_info ()
                        | Error err -> Lwt_io.printf "Error: %s\n" err ) ) ) )
          |> Lwt.async ;
          Server.respond_string ~status:`OK
            ~body:(f "Received a request to run CI: not implemented yet.")
            ()
      | Ok (GitHub_subscriptions.CommentCreated comment_info)
        when string_match ~regexp:"@coqbot: [Mm]erge now" comment_info.body ->
          Server.respond_string ~status:`OK
            ~body:
              (f "Received a request to merge the PR: not implemented yet.")
            ()
      | Ok (GitHub_subscriptions.CommentCreated comment_info) ->
          Server.respond_string ~status:`OK
            ~body:
              (f
                 "Pull request comment doesn't contain any request to \
                  @coqbot: nothing to do.")
            ()
      | Ok (GitHub_subscriptions.NoOp s) ->
          Server.respond_string ~status:`OK
            ~body:(f "No action taken: %s" s)
            ()
      | Ok _ ->
          Server.respond_string ~status:`OK
            ~body:"No action taken: event or action is not yet supported." ()
      | Error s ->
          Server.respond ~status:(Code.status_of_code 400)
            ~body:(Cohttp_lwt.Body.of_string (f "Error: %s" s))
            () )
  | _ -> Server.respond_not_found ()

let server =
  print_endline "Initializing repository" ;
  "git config --global user.email \"coqbot@users.noreply.github.com\""
  |&& "git config --global user.name \"coqbot\"" |&& "git init --bare"
  |> execute_cmd |> Lwt.ignore_result ;
  let mode = `TCP (`Port port) in
  Server.create ~mode (Server.make ~callback ())

let () = Lwt_main.run server
