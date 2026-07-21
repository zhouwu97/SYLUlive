import json

import httpx
import pytest

from scripts.probe_academic_sources import (
    ACADEMIC_URL,
    AcademicSourceProbe,
    RequestCandidate,
    _allowed_post_path,
    _assert_no_credentials,
    _is_safe_read_candidate,
    _response_runtime_bindings,
    _safe_alias,
    _select_business_script_paths,
    analyze_html_structure,
    build_cross_sample_summary,
    diagnose_courses_empty,
    discover_script_candidates,
    discover_menu_candidates,
    render_cross_sample_report,
    summarize_response,
)


def _response(body: str, content_type: str = "text/html") -> httpx.Response:
    return httpx.Response(
        200,
        text=body,
        headers={"content-type": content_type},
        request=httpx.Request("GET", ACADEMIC_URL),
    )


def test_html_probe_extracts_structure_without_values():
    html = """
    <html><body>
      <form action="/xsxy/query.html?gnmkdm=N105515" method="post">
        <input type="hidden" name="student_id" value="2024123456">
        <input type="hidden" name="token" value="private-token">
      </form>
      <iframe src="/xsxy/frame.html"></iframe>
      <div data-url="/xsxy/data_cxList.html"></div>
      <table><tr><th>课程名称</th><th>最大成绩</th><th>修读状态</th></tr></table>
      <script src="/js/academic.js?v=secret"></script>
      <script>
        $.ajax({url: '/xsxy/course_cxList.html', type: 'POST', data: {plan_id: pid}});
        fetch('/xsxy/summary_cxList.html');
        $('#target').load('/xsxy/module_cxList.html');
        $('#table').DataTable({ajax: '/xsxy/table_cxList.html'});
      </script>
      张三 2024123456 高等数学 91
    </body></html>
    """

    summary, candidates = analyze_html_structure(html, ACADEMIC_URL)
    serialized = json.dumps(summary, ensure_ascii=False)
    paths = {candidate.source_url for candidate in candidates}

    assert summary["form_count"] == 1
    assert summary["iframe_sources"] == ["/xsxy/frame.html"]
    assert summary["script_sources"] == ["/js/academic.js"]
    assert summary["course_table_present"] is True
    assert summary["course_data_row_count"] == 0
    assert summary["script_marker_counts"]["$.ajax"] == 1
    assert summary["unresolved_dynamic_reference_count"] == 0
    assert "/xsxy/course_cxList.html" in paths
    assert "/xsxy/summary_cxList.html" in paths
    assert "/xsxy/module_cxList.html" in paths
    assert "/xsxy/table_cxList.html" in paths
    assert "2024123456" not in serialized
    assert "private-token" not in serialized
    assert "张三" not in serialized
    assert "高等数学" not in serialized


def test_menu_candidates_keep_menu_contract_and_require_url():
    html = """
      <a href="/bysh/bysh_cxIndex.html?gnmkdm=N900101">毕业审核</a>
      <button onclick="openMenu('N900102')">培养方案</button>
      <a href="https://evil.example/steal">毕业预警</a>
    """

    candidates, without_url = discover_menu_candidates(html, ACADEMIC_URL)

    assert len(candidates) == 1
    assert candidates[0].name == "毕业审核"
    assert candidates[0].gnmkdm == "N900101"
    assert candidates[0].source_url == "/bysh/bysh_cxIndex.html"
    assert candidates[0].parameter_names == ("gnmkdm", "layout")
    assert candidates[0].form_data == {
        "gnmkdm": "N900101",
        "layout": "default",
    }
    assert {item["name"] for item in without_url} == {"培养方案", "毕业预警"}


def test_script_candidates_resolve_concatenated_paths_and_ignore_plain_url_fields():
    script = r"""
      var _path = "/jxzxjhgl";
      var url1 = _path + "/jxzxjhkcxx_cxJxzxjhkcxxIndex.html?doType=query";
      var unrelated = {url: config.avatar};
      $.ajax({url: url1, type: "POST", data: {jxzxjhxx_id: planId}});
    """

    candidates = discover_script_candidates(
        script,
        ACADEMIC_URL,
        source="external_script:/js/comp/jwglxt/jxzxjhck.js",
    )
    summary, _ = analyze_html_structure(f"<script>{script}</script>", ACADEMIC_URL)

    assert len(candidates) == 1
    assert candidates[0].source_url == ("/jxzxjhgl/jxzxjhkcxx_cxJxzxjhkcxxIndex.html")
    assert candidates[0].method == "POST"
    assert "jxzxjhxx_id" in candidates[0].parameter_names
    assert summary["unresolved_dynamic_reference_count"] == 0


def test_real_jquery_and_jqgrid_patterns_keep_request_parameters():
    script = r"""
      function paramterMap(){
        return {
          // "xh_id": $("#xh_id").val(),
          "bynd": $("#bynd").val(),
          "doType": "query"
        };
      }
      var url1 = _path + "/bygl/bysh_cxByshjgHcIndex.html";
      jQuery.ajax({url: url1, data: paramterMap(), type: "post"});

      function planParams(){
        return {"jg_id": jQuery("#jg_id").val()};
      }
      var grid = $.extend({}, BaseJqGrid, {
        postData: planParams(),
        url: _path + "/jxzxjhgl/query.html?doType=query"
      });
      var unrelated = $.extend({}, defaults);
    """

    candidates = discover_script_candidates(script, ACADEMIC_URL, source="fixture")

    assert [(item.method, item.source_url) for item in candidates] == [
        ("POST", "/bygl/bysh_cxByshjgHcIndex.html"),
        ("POST", "/jxzxjhgl/query.html"),
    ]
    assert candidates[0].parameter_names == ("bynd", "doType")
    assert candidates[0].form_data == {"doType": "query"}
    assert candidates[0].parameter_controls == {"bynd": "bynd"}
    assert candidates[1].parameter_names == ("doType", "jg_id")
    assert candidates[1].parameter_controls == {"jg_id": "jg_id"}


def test_dynamic_query_value_becomes_parameterized_candidate():
    script = r"""
      function openPlan(id) {
        $.ajax({
          type: "POST",
          url: _path + "/jxzxjhgl/detail_cxList.html?jxzxjhxx_id=" + id
        });
      }
    """

    candidates = discover_script_candidates(script, ACADEMIC_URL, source="fixture")

    assert len(candidates) == 1
    assert candidates[0].source_url == "/jxzxjhgl/detail_cxList.html"
    assert candidates[0].parameter_names == ("jxzxjhxx_id",)


def test_runtime_binding_extraction_is_limited_to_plan_identifiers():
    response = _response(
        json.dumps(
            {
                "items": [
                    {
                        "jxzxjhxx_id": "private-plan-id",
                        "student_id": "must-not-bind",
                        "course_name": "must-not-bind",
                    }
                ]
            }
        ),
        "application/json",
    )

    assert _response_runtime_bindings(response) == {"jxzxjhxx_id": "private-plan-id"}


def test_unresolved_count_only_tracks_dynamic_request_contexts():
    summary, _ = analyze_html_structure(
        "<script>var config = {url: basePath + '/avatar'};</script>",
        ACADEMIC_URL,
    )

    assert summary["unresolved_dynamic_reference_count"] == 0


def test_business_script_filter_normalizes_paths_and_drops_common_assets():
    selected = _select_business_script_paths(
        [
            r"\js\comp\jwglxt\bygl\bysh.js",
            "/js/common/jquery.js",
            "/js/plugins/bootstrap.js",
            "/js/i18n/messages.js",
        ]
    )

    assert selected == ["/js/comp/jwglxt/bygl/bysh.js"]


def test_menu_duplicate_without_url_does_not_block_verified_same_name():
    html = """
      <button>毕业审核</button>
      <a href="/bysh/bysh_cxIndex.html?gnmkdm=N900101">毕业审核</a>
    """

    candidates, without_url = discover_menu_candidates(html, ACADEMIC_URL)

    assert len(candidates) == 1
    assert without_url == []


def test_response_summary_only_keeps_json_shape_and_business_flags():
    response = _response(
        json.dumps(
            {
                "plan_id": "private-plan-123",
                "modules": [
                    {
                        "module_name": "专业课",
                        "required_credits": 40,
                        "earned_credits": 35,
                        "remaining_credits": 5,
                        "course_name": "高等数学",
                    }
                ],
                "student_id": "2024123456",
            },
            ensure_ascii=False,
        ),
        "application/json",
    )

    summary = summarize_response(
        name="候选",
        source_url="/bysh/query.html",
        method="POST",
        parameter_names=("gnmkdm", "plan_id"),
        response=response,
    )
    serialized = json.dumps(summary, ensure_ascii=False)

    assert summary["contains_plan_id"] is True
    assert summary["contains_module_groups"] is True
    assert summary["contains_required_credits"] is True
    assert summary["contains_earned_credits"] is True
    assert summary["contains_remaining_credits"] is True
    assert summary["contains_course_details"] is True
    assert summary["has_non_empty_required_credits"] is True
    assert summary["has_non_empty_earned_credits"] is True
    assert summary["has_non_empty_remaining_credits"] is True
    assert summary["has_non_empty_module_record"] is True
    assert summary["has_non_empty_course_record"] is True
    assert summary["stable_for_current_account"] is True
    assert "private-plan-123" not in serialized
    assert "2024123456" not in serialized
    assert "高等数学" not in serialized


def test_response_summary_preserves_valid_json_null_shape():
    summary = summarize_response(
        name="毕业审核查询",
        source_url="/bygl/bysh_cxByshjgHcIndex.html",
        method="POST",
        parameter_names=("bynd", "doType"),
        response=_response("null", "application/json"),
    )

    assert summary["content_type"] == "application/json"
    assert summary["response_shape"] == {"type": "NoneType"}
    assert summary["verification_status"] == (
        "responded_without_verified_business_fields"
    )


def test_execution_plan_field_aliases_are_structural_evidence():
    summary = summarize_response(
        name="执行计划",
        source_url="/jxzxjhgl/query.html",
        method="POST",
        parameter_names=(),
        response=_response(
            json.dumps({"items": [{"jxzxjhxx_id": "private", "zdxf": 160}]}),
            "application/json",
        ),
    )

    assert summary["contains_plan_id"] is True
    assert summary["contains_required_credits"] is True
    assert summary["has_non_empty_required_credits"] is True


def test_response_summary_redacts_data_shaped_json_keys_and_table_headers():
    json_summary = summarize_response(
        name="候选",
        source_url="/bysh/query.html",
        method="GET",
        parameter_names=(),
        response=_response(
            json.dumps(
                {
                    "items": {
                        "高等数学": {"course_name": "高等数学"},
                        "2024123456": {"status": "通过"},
                    }
                },
                ensure_ascii=False,
            ),
            "application/json",
        ),
    )
    html_summary = summarize_response(
        name="候选",
        source_url="/bysh/query.html",
        method="GET",
        parameter_names=(),
        response=_response(
            "<table><tr><th>课程名称</th><th>张三成绩</th></tr></table>"
        ),
    )

    serialized = json.dumps([json_summary, html_summary], ensure_ascii=False)
    assert "高等数学" not in serialized
    assert "2024123456" not in serialized
    assert "张三成绩" not in serialized
    assert (
        json_summary["response_shape"]["children"]["items"]["redacted_key_count"] == 2
    )
    assert html_summary["response_shape"]["table_headers"] == ["课程名称"]


def test_html_business_evidence_requires_and_accepts_non_empty_rows():
    summary = summarize_response(
        name="毕业完成度候选",
        source_url="/bysh/query.html",
        method="GET",
        parameter_names=(),
        response=_response(
            """
              <table>
                <tr>
                  <th>模块名称</th><th>要求学分</th><th>已修学分</th>
                  <th>剩余学分</th><th>课程名称</th>
                </tr>
                <tr><td>专业模块</td><td>40</td><td>35</td><td>5</td><td>课程值</td></tr>
              </table>
            """
        ),
    )

    assert summary["has_non_empty_required_credits"] is True
    assert summary["has_non_empty_earned_credits"] is True
    assert summary["has_non_empty_remaining_credits"] is True
    assert summary["has_non_empty_module_record"] is True
    assert summary["has_non_empty_course_record"] is True
    assert "专业模块" not in json.dumps(summary, ensure_ascii=False)
    assert "课程值" not in json.dumps(summary, ensure_ascii=False)


def test_structure_signature_ignores_json_array_length():
    first = summarize_response(
        name="候选",
        source_url="/bysh/query.html",
        method="POST",
        parameter_names=(),
        response=_response(
            json.dumps({"items": [{"course_name": "A"}]}),
            "application/json",
        ),
    )
    second = summarize_response(
        name="候选",
        source_url="/bysh/query.html",
        method="POST",
        parameter_names=(),
        response=_response(
            json.dumps({"items": [{"course_name": "B"}, {"course_name": "C"}]}),
            "application/json",
        ),
    )

    assert first["response_shape"]["children"]["items"]["length"] == 1
    assert second["response_shape"]["children"]["items"]["length"] == 2
    assert first["structure_signature"] == second["structure_signature"]


def test_only_same_origin_read_candidates_are_requested():
    safe = RequestCandidate(
        name="查询",
        url="https://jxw.sylu.edu.cn/bysh/bysh_cxList.html",
        method="POST",
    )
    mutation = RequestCandidate(
        name="保存",
        url="https://jxw.sylu.edu.cn/bysh/bysh_save.html",
        method="POST",
    )

    assert _is_safe_read_candidate(safe) is True
    assert _is_safe_read_candidate(mutation) is False


def test_courses_empty_requires_verified_response_before_claiming_dynamic_source():
    structure = {
        "course_table_present": False,
        "course_data_row_count": 0,
        "script_marker_counts": {"$.ajax": 1},
        "unresolved_dynamic_reference_count": 1,
    }
    unresolved = diagnose_courses_empty(structure, [])
    verified = diagnose_courses_empty(
        structure,
        [
            {
                "source_url": "/xsxy/course_cxList.html",
                "method": "POST",
                "content_type": "application/json",
                "required_parameters": ["plan_id"],
                "stable_for_current_account": True,
                "contains_course_details": True,
            }
        ],
    )

    assert unresolved["result"] == "dynamic_candidates_not_verified"
    assert verified["result"] == "courses_loaded_by_verified_dynamic_request"
    assert (
        verified["verified_dynamic_source"]["source_url"] == "/xsxy/course_cxList.html"
    )


def test_courses_empty_recognizes_data_source_without_ajax_marker():
    result = diagnose_courses_empty(
        {
            "course_table_present": False,
            "course_data_row_count": 0,
            "script_marker_counts": {},
            "data_sources": ["/xsxy/course_cxList.html"],
            "iframe_sources": [],
        },
        [],
    )

    assert result["result"] == "dynamic_candidates_not_verified"


def _sample_report(sample_id: str, cohort: str, major: str, content_type: str):
    return {
        "probe_version": "academic-source-probe-v3",
        "sample": {
            "id": sample_id,
            "cohort_alias": cohort,
            "major_alias": major,
            "college_alias": f"college-{sample_id}",
        },
        "verified_requests": [
            {
                "method": "POST",
                "source_url": "/bysh/query.html",
                "content_type": content_type,
                "structure_signature": "same-structure",
                "stable_for_current_account": True,
                "contains_module_groups": True,
                "contains_required_credits": True,
                "contains_earned_credits": True,
                "contains_remaining_credits": True,
                "contains_course_details": True,
                "has_non_empty_required_credits": True,
                "has_non_empty_earned_credits": True,
                "has_non_empty_remaining_credits": True,
                "has_non_empty_module_record": True,
                "has_non_empty_course_record": True,
            }
        ],
        "probe_completeness": {"complete": True, "blockers": []},
    }


def test_cross_sample_summary_requires_coverage_before_route_decision():
    result = build_cross_sample_summary(
        [_sample_report("sample-a", "cohort-a", "major-a", "application/json")]
    )

    assert result["decision_status"] == "INCONCLUSIVE"
    assert result["route"] is None


def test_cross_sample_summary_rejects_legacy_probe_reports():
    report = _sample_report("sample-a", "cohort-a", "major-a", "application/json")
    report["probe_version"] = "academic-source-probe-v2"

    with pytest.raises(ValueError, match="报告版本不一致"):
        build_cross_sample_summary([report])


@pytest.mark.parametrize(
    ("content_type", "expected_route"),
    (("application/json", "A"), ("text/html", "B")),
)
def test_cross_sample_summary_selects_verified_official_route(
    content_type, expected_route
):
    reports = [
        _sample_report("sample-a", "cohort-a", "major-a", content_type),
        _sample_report("sample-b", "cohort-b", "major-b", content_type),
    ]
    for report in reports:
        report["verified_requests"][0]["contains_course_details"] = False
        report["verified_requests"][0]["has_non_empty_course_record"] = False

    result = build_cross_sample_summary(reports)

    assert result["decision_status"] == "READY"
    assert result["route"] == expected_route
    assert result["coverage"]["preferred_two_colleges_met"] is True


def test_cross_sample_summary_uses_route_c_only_after_minimum_coverage():
    reports = [
        _sample_report("sample-a", "cohort-a", "major-a", "application/json"),
        _sample_report("sample-b", "cohort-b", "major-b", "application/json"),
    ]
    reports[1]["verified_requests"] = []

    result = build_cross_sample_summary(reports)

    assert result["decision_status"] == "READY"
    assert result["route"] == "C"


def test_cross_sample_summary_does_not_use_route_c_with_probe_blockers():
    reports = [
        _sample_report("sample-a", "cohort-a", "major-a", "application/json"),
        _sample_report("sample-b", "cohort-b", "major-b", "application/json"),
    ]
    for report in reports:
        report["verified_requests"] = []
    reports[1]["probe_completeness"] = {
        "complete": False,
        "blockers": ["candidate_request_failed"],
    }

    result = build_cross_sample_summary(reports)

    assert result["decision_status"] == "INCONCLUSIVE"
    assert result["route"] is None
    assert result["all_probes_complete"] is False


@pytest.mark.parametrize(
    ("body", "content_type", "forbidden_route"),
    (
        (
            json.dumps(
                {
                    "modules": [
                        {
                            "module_name": None,
                            "required_credits": None,
                            "earned_credits": None,
                            "remaining_credits": None,
                            "course_name": "仅用于内存证据",
                        }
                    ]
                },
                ensure_ascii=False,
            ),
            "application/json",
            "A",
        ),
        (
            """
              <table><tr>
                <th>模块名称</th><th>要求学分</th><th>已修学分</th>
                <th>剩余学分</th><th>课程名称</th>
              </tr></table>
            """,
            "text/html",
            "B",
        ),
    ),
)
def test_empty_business_values_cannot_select_official_route(
    body, content_type, forbidden_route
):
    response_summary = summarize_response(
        name="毕业完成度候选",
        source_url="/bysh/query.html",
        method="GET",
        parameter_names=(),
        response=_response(body, content_type),
    )
    reports = [
        _sample_report("sample-a", "cohort-a", "major-a", content_type),
        _sample_report("sample-b", "cohort-b", "major-b", content_type),
    ]
    for report in reports:
        report["verified_requests"] = [dict(response_summary)]

    result = build_cross_sample_summary(reports)

    assert response_summary["stable_for_current_account"] is True
    assert response_summary["has_non_empty_required_credits"] is False
    assert response_summary["has_non_empty_earned_credits"] is False
    assert response_summary["has_non_empty_remaining_credits"] is False
    assert result["route"] != forbidden_route
    assert result["stable_sources"][0]["graduation_fields_complete"] is False


@pytest.mark.asyncio
async def test_non_menu_skipped_candidate_blocks_route_c():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/xtgl/index_initMenu.html":
            return httpx.Response(200, text="<main>首页</main>", request=request)
        return httpx.Response(
            200,
            text='<iframe src="/opaque/process.html"></iframe>',
            request=request,
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        first = await AcademicSourceProbe(client, "JSESSIONID=secret").run(
            {
                "id": "sample-a",
                "cohort_alias": "cohort-a",
                "major_alias": "major-a",
                "college_alias": "college-a",
            }
        )
    second = json.loads(json.dumps(first))
    second["sample"] = {
        "id": "sample-b",
        "cohort_alias": "cohort-b",
        "major_alias": "major-b",
        "college_alias": "college-b",
    }

    result = build_cross_sample_summary([first, second])

    assert "candidate_not_verified_read_only" in first["probe_completeness"]["blockers"]
    assert first["unverified_candidates"] == [
        {
            "source_url": "/opaque/process.html",
            "method": "GET",
            "verification_status": "skipped_not_proven_read_only",
            "unresolved_parameters": [],
        }
    ]
    assert result["decision_status"] == "INCONCLUSIVE"
    assert result["route"] is None


@pytest.mark.asyncio
async def test_dynamic_expression_url_blocks_route_c():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/xtgl/index_initMenu.html":
            return httpx.Response(200, text="<main>首页</main>", request=request)
        return httpx.Response(
            200,
            text="<script>fetch(buildUrl(planId));</script>",
            request=request,
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        first = await AcademicSourceProbe(client, "JSESSIONID=secret").run(
            {
                "id": "sample-a",
                "cohort_alias": "cohort-a",
                "major_alias": "major-a",
                "college_alias": "college-a",
            }
        )
    second = json.loads(json.dumps(first))
    second["sample"] = {
        "id": "sample-b",
        "cohort_alias": "cohort-b",
        "major_alias": "major-b",
        "college_alias": "college-b",
    }

    result = build_cross_sample_summary([first, second])

    assert first["unresolved_dynamic_reference_count"] == 1
    assert (
        "dynamic_request_reference_unresolved"
        in first["probe_completeness"]["blockers"]
    )
    assert result["decision_status"] == "INCONCLUSIVE"
    assert result["route"] is None


@pytest.mark.asyncio
async def test_known_read_state_mutation_is_reported_without_request_or_blocker():
    requested = []

    def handler(request: httpx.Request) -> httpx.Response:
        requested.append((request.method, request.url.path))
        if request.url.path == "/xtgl/index_initMenu.html":
            return httpx.Response(200, text="<main>首页</main>", request=request)
        if request.url.path == "/xsxy/xsxyqk_cxXsxyqkIndex.html":
            return httpx.Response(
                200,
                text="""
                  <script>
                    jQuery.ajax({
                      url: '/xyyjgl/xyyj_cxZjxgsfyd.html',
                      type: 'POST',
                      data: {ydzt: flag, sfyd: '1'}
                    });
                  </script>
                """,
                request=request,
            )
        raise AssertionError(f"不应请求状态变更候选：{request.url.path}")

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        report = await AcademicSourceProbe(client, "JSESSIONID=secret").run(
            {
                "id": "sample-a",
                "cohort_alias": "cohort-a",
                "major_alias": "major-a",
                "college_alias": "college-a",
            }
        )

    assert requested == [
        ("GET", "/xtgl/index_initMenu.html"),
        ("GET", "/xsxy/xsxyqk_cxXsxyqkIndex.html"),
    ]
    assert report["excluded_state_changing_candidates"] == [
        {
            "source_url": "/xyyjgl/xyyj_cxZjxgsfyd.html",
            "method": "POST",
            "reason": "known_state_changing_request",
            "parameter_names": ["sfyd", "ydzt"],
        }
    ]
    assert report["probe_completeness"] == {"complete": True, "blockers": []}
    assert report["courses_empty_diagnosis"]["result"] == "no_course_source_found"


@pytest.mark.asyncio
async def test_unresolved_candidate_parameters_prevent_complete_probe():
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/xtgl/index_initMenu.html":
            return httpx.Response(200, text="<main>首页</main>", request=request)
        if request.url.path == "/xsxy/xsxyqk_cxXsxyqkIndex.html":
            return httpx.Response(
                200,
                text="""
                  当前所有课程平均学分绩点（GPA）：3.2
                  当前学位课程平均学分绩点（GPA）：3.1
                  计划总课程 100 门 通过 80 门 未通过 1 门 未修 10 门 在读 9 门
                  计划学位课程 20 门 通过 16 门 未通过 1 门 未修 2 门 在读 1 门
                  <script>
                    $.ajax({url: '/xsxy/course_cxList.html', data: {plan_id: pid}});
                  </script>
                """,
                request=request,
            )
        return httpx.Response(200, json={"items": []}, request=request)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        report = await AcademicSourceProbe(
            client,
            "JSESSIONID=secret",
            allowed_post_paths=("/xsxy/course_cxList.html",),
        ).run(
            {
                "id": "sample-a",
                "cohort_alias": "cohort-a",
                "major_alias": "major-a",
                "college_alias": "college-a",
            }
        )

    dynamic = next(
        item
        for item in report["verified_requests"]
        if item["source_url"] == "/xsxy/course_cxList.html"
    )
    assert dynamic["unresolved_parameters"] == ["plan_id"]
    assert report["probe_completeness"]["complete"] is False
    assert "candidate_parameters_unresolved" in report["probe_completeness"]["blockers"]


def test_cross_sample_markdown_uses_required_nine_sections():
    reports = [
        _sample_report("sample-a", "cohort-a", "major-a", "application/json"),
        _sample_report("sample-b", "cohort-b", "major-b", "application/json"),
    ]
    for report in reports:
        report["menu_candidates"] = []
        report["courses_empty_diagnosis"] = {"result": "no_course_source_found"}
    summary = build_cross_sample_summary(reports)

    markdown = render_cross_sample_report(summary, reports)

    for index, title in enumerate(
        (
            "探测范围",
            "已验证菜单",
            "已验证请求",
            "courses=[] 原因",
            "独立毕业接口结论",
            "多专业多年级差异",
            "隐私和安全检查",
            "最终路线 A / B / C",
            "下一阶段建议",
        ),
        start=1,
    ):
        assert f"## {index}. {title}" in markdown


def test_aliases_and_final_secret_guard_reject_personal_identifiers():
    assert _safe_alias("sample-a", "--sample-id") == "sample-a"
    with pytest.raises(ValueError):
        _safe_alias("2024123456", "--sample-id")
    with pytest.raises(RuntimeError):
        _assert_no_credentials({"value": "cookie-secret"}, ("cookie-secret",))


def test_allowed_post_path_requires_exact_non_mutating_path():
    assert _allowed_post_path("/xsxy/course_cxList.html") == (
        "/xsxy/course_cxList.html"
    )
    with pytest.raises(ValueError):
        _allowed_post_path("/xsxy/course_save.html")
    with pytest.raises(ValueError):
        _allowed_post_path("/xsxy/course_cxList.html?plan_id=private")
    with pytest.raises(ValueError):
        _allowed_post_path("https://evil.example/query")


@pytest.mark.asyncio
async def test_candidate_verification_skips_mutation_without_network_request():
    requested = []

    def handler(request: httpx.Request) -> httpx.Response:
        requested.append(str(request.url))
        return httpx.Response(200, text="ok", request=request)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        probe = AcademicSourceProbe(
            client,
            "JSESSIONID=secret",
            allowed_post_paths=("/bysh/bysh_save.html",),
        )
        result = await probe._request_candidate(
            RequestCandidate(
                name="保存",
                url="https://jxw.sylu.edu.cn/bysh/bysh_save.html",
                method="POST",
            )
        )

    assert result["verification_status"] == "skipped_not_proven_read_only"
    assert requested == []


@pytest.mark.asyncio
async def test_post_candidate_requires_exact_manual_allow_path():
    requested = []

    def handler(request: httpx.Request) -> httpx.Response:
        requested.append((request.method, request.url.path))
        return httpx.Response(200, json={"items": []}, request=request)

    candidate = RequestCandidate(
        name="课程查询",
        url="https://jxw.sylu.edu.cn/xsxy/opaqueEndpoint.html",
        method="POST",
    )
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        skipped = await AcademicSourceProbe(
            client, "JSESSIONID=secret"
        )._request_candidate(candidate)
        allowed = await AcademicSourceProbe(
            client,
            "JSESSIONID=secret",
            allowed_post_paths=("/xsxy/opaqueEndpoint.html",),
        )._request_candidate(candidate)

    assert skipped["verification_status"] == "skipped_post_not_allowed"
    assert allowed["verification_status"] == (
        "responded_without_verified_business_fields"
    )
    assert requested == [("POST", "/xsxy/opaqueEndpoint.html")]


@pytest.mark.asyncio
@pytest.mark.parametrize("method", ("GET", "POST"))
async def test_candidate_parameters_are_sent_but_not_exposed(method):
    captured = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured["query"] = dict(request.url.params)
        captured["body"] = (await request.aread()).decode()
        return httpx.Response(
            200,
            json={"items": [{"course_name": "不落盘课程"}]},
            request=request,
        )

    candidate = RequestCandidate(
        name="课程查询",
        url="https://jxw.sylu.edu.cn/xsxy/course_cxList.html?gnmkdm=N105515",
        method=method,
        parameter_names=("gnmkdm", "plan_id"),
        form_data={"plan_id": "private-plan-123"},
    )
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        allowed_post_paths = ("/xsxy/course_cxList.html",) if method == "POST" else ()
        result = await AcademicSourceProbe(
            client,
            "JSESSIONID=cookie-secret",
            allowed_post_paths=allowed_post_paths,
        )._request_candidate(candidate)

    if method == "GET":
        assert captured["query"] == {
            "gnmkdm": "N105515",
            "plan_id": "private-plan-123",
        }
        assert captured["body"] == ""
    else:
        assert captured["query"] == {"gnmkdm": "N105515"}
        assert captured["body"] == "plan_id=private-plan-123"

    serialized = json.dumps(result, ensure_ascii=False)
    assert result["required_parameters"] == ["gnmkdm", "plan_id"]
    assert "private-plan-123" not in serialized
    assert "cookie-secret" not in serialized
    assert "不落盘课程" not in serialized


@pytest.mark.asyncio
async def test_external_script_is_fetched_before_dynamic_candidate_verification():
    requests = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append((request.method, request.url.path))
        if request.url.path == "/xtgl/index_initMenu.html":
            return httpx.Response(200, text="<main>首页</main>", request=request)
        if request.url.path == "/xsxy/xsxyqk_cxXsxyqkIndex.html":
            return httpx.Response(
                200,
                text='<script src="/js/academic.js"></script>',
                request=request,
            )
        if request.url.path == "/js/academic.js":
            return httpx.Response(
                200,
                text="""
                  $.ajax({
                    url: '/xsxy/course_cxList.html',
                    type: 'POST',
                    data: {plan_id: 'private-plan-123'}
                  });
                """,
                headers={"content-type": "application/javascript"},
                request=request,
            )
        if request.url.path == "/xsxy/course_cxList.html":
            return httpx.Response(
                200,
                json={"items": [{"course_name": "不落盘课程"}]},
                request=request,
            )
        return httpx.Response(404, request=request)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        report = await AcademicSourceProbe(
            client,
            "JSESSIONID=secret",
            allowed_post_paths=("/xsxy/course_cxList.html",),
        ).run(
            {
                "id": "sample-a",
                "cohort_alias": "cohort-a",
                "major_alias": "major-a",
                "college_alias": "college-a",
            }
        )

    serialized = json.dumps(report, ensure_ascii=False)
    assert ("GET", "/js/academic.js") in requests
    assert ("POST", "/xsxy/course_cxList.html") in requests
    assert report["external_scripts"][0]["candidate_count"] == 1
    assert report["courses_empty_diagnosis"]["result"] == (
        "courses_loaded_by_verified_dynamic_request"
    )
    assert report["probe_completeness"]["complete"] is True
    assert "private-plan-123" not in serialized
    assert "不落盘课程" not in serialized


@pytest.mark.asyncio
async def test_menu_shell_uses_contract_and_discovers_page_specific_script():
    requests = []

    async def handler(request: httpx.Request) -> httpx.Response:
        requests.append(
            (
                request.method,
                request.url.path,
                dict(request.url.params),
                (await request.aread()).decode(),
            )
        )
        if request.url.path == "/xtgl/index_initMenu.html":
            return httpx.Response(
                200,
                text=(
                    '<a href="/bygl/bysh_cxByshjgHcIndex.html?gnmkdm=N105508">'
                    "毕业审核</a>"
                ),
                request=request,
            )
        if request.url.path == "/xsxy/xsxyqk_cxXsxyqkIndex.html":
            return httpx.Response(200, text="<main>学业汇总</main>", request=request)
        if request.method == "POST" and request.url.path == (
            "/bygl/bysh_cxByshjgHcIndex.html"
        ):
            return httpx.Response(
                200,
                text="null",
                headers={"content-type": "application/json"},
                request=request,
            )
        if request.url.path == "/bygl/bysh_cxByshjgHcIndex.html":
            assert dict(request.url.params) == {
                "gnmkdm": "N105508",
                "layout": "default",
            }
            return httpx.Response(
                200,
                text="""
                  <select id="bynd"><option value="2026" selected>年度</option></select>
                  <script src="/js/common/jquery.js"></script>
                  <script src="/js/comp/jwglxt/bygl/bysh.js"></script>
                """,
                request=request,
            )
        if request.url.path == "/js/comp/jwglxt/bygl/bysh.js":
            return httpx.Response(
                200,
                text="""
                  var _path = "/bygl";
                  var queryUrl = _path + "/bysh_cxByshjgHcIndex.html";
                  $.ajax({
                    url: queryUrl,
                    type: "POST",
                    data: {bynd: $("#bynd").val(), doType: "query"}
                  });
                """,
                headers={"content-type": "application/javascript"},
                request=request,
            )
        return httpx.Response(404, request=request)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        report = await AcademicSourceProbe(
            client,
            "JSESSIONID=secret",
            allowed_post_paths=("/bygl/bysh_cxByshjgHcIndex.html",),
        ).run(
            {
                "id": "sample-a",
                "cohort_alias": "cohort-a",
                "major_alias": "major-a",
                "college_alias": "college-a",
            }
        )

    post = next(
        item
        for item in report["verified_requests"]
        if item["method"] == "POST"
        and item["source_url"] == "/bygl/bysh_cxByshjgHcIndex.html"
    )
    assert post["parameters_complete"] is True
    assert post["response_shape"] == {"type": "NoneType"}
    assert report["external_scripts"] == [
        {
            "source_url": "/js/comp/jwglxt/bygl/bysh.js",
            "status_code": 200,
            "content_type": "application/javascript",
            "candidate_count": 1,
            "unresolved_dynamic_reference_count": 0,
            "verification_status": "verified",
        }
    ]
    assert report["probe_completeness"] == {"complete": True, "blockers": []}


@pytest.mark.asyncio
async def test_full_probe_flow_verifies_menu_and_dynamic_course_source():
    requests = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append((request.method, request.url.path))
        if request.url.path == "/xtgl/index_initMenu.html":
            body = """
              <a href="/bysh/bysh_cxIndex.html?gnmkdm=N900101">毕业审核</a>
            """
            return httpx.Response(200, text=body, request=request)
        if request.url.path == "/xsxy/xsxyqk_cxXsxyqkIndex.html":
            body = """
              当前所有课程平均学分绩点（GPA）：3.2
              当前学位课程平均学分绩点（GPA）：3.1
              计划总课程 100 门 通过 80 门 未通过 1 门 未修 10 门 在读 9 门
              计划学位课程 20 门 通过 16 门 未通过 1 门 未修 2 门 在读 1 门
              <script>$.ajax({url: '/xsxy/course_cxList.html', type: 'POST'});</script>
            """
            return httpx.Response(200, text=body, request=request)
        if request.url.path == "/xsxy/course_cxList.html":
            body = json.dumps({"items": [{"course_name": "不落盘课程"}]})
            return httpx.Response(
                200,
                text=body,
                headers={"content-type": "application/json"},
                request=request,
            )
        if request.url.path == "/bysh/bysh_cxIndex.html":
            body = """
              培养方案编号：P1 培养模块 要求学分 40 已获得学分 35 剩余学分 5
              <table><tr><th>课程名称</th></tr><tr><td>不落盘课程</td></tr></table>
            """
            return httpx.Response(200, text=body, request=request)
        return httpx.Response(404, text="", request=request)

    async with httpx.AsyncClient(
        transport=httpx.MockTransport(handler),
        follow_redirects=False,
    ) as client:
        probe = AcademicSourceProbe(
            client,
            "JSESSIONID=cookie-secret",
            allowed_post_paths=("/xsxy/course_cxList.html",),
        )
        report = await probe.run(
            {
                "id": "sample-a",
                "cohort_alias": "cohort-a",
                "major_alias": "major-a",
                "college_alias": "college-a",
            }
        )

    serialized = json.dumps(report, ensure_ascii=False)
    assert ("GET", "/xtgl/index_initMenu.html") in requests
    assert ("GET", "/xsxy/xsxyqk_cxXsxyqkIndex.html") in requests
    assert ("POST", "/xsxy/course_cxList.html") in requests
    assert ("GET", "/bysh/bysh_cxIndex.html") in requests
    assert report["courses_empty_diagnosis"]["result"] == (
        "courses_loaded_by_verified_dynamic_request"
    )
    assert report["menu_candidates"][0]["verification_status"] == (
        "verified_business_response"
    )
    assert report["probe_completeness"]["complete"] is True
    assert "cookie-secret" not in serialized
    assert "不落盘课程" not in serialized
