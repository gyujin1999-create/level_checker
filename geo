import React, { useState, useMemo } from "react";
import {
  ArrowRight, BarChart3, Check, ChevronRight, ClipboardCheck, FileText,
  Lock, Radar, RefreshCcw, ShieldCheck, Trophy, TrendingDown, WalletCards,
  Store, ShoppingBag, AppWindow, Sparkles, AlertTriangle, CheckCircle2,
  XCircle, MinusCircle, FileSearch, Wrench,
} from "lucide-react";

// CiteRadar v4 "deep" — 측정에서 처방으로 무게 이동
// 세 기둥:
//  1) 단계적 멀티LLM: 무료=1개(ChatGPT계열 대리), 유료=+Perplexity, 상위=+Gemini
//     (데모는 Claude로 측정하고, 엔진별 결과는 동일 측정 + 라벨로 표현. 배포 시 실제 엔진별 호출)
//  2) 3단계 노출: 언급(0.3)/추천(0.7)/인용(1.0) 가중 — 단순 등장이 아니라 인용 지향
//  3) GEO 레시피 처방: 사용자가 페이지 내용을 붙여넣으면 실제 분석
//     (직접답변 40-60단어 / 사실밀도 / 스키마 / 엔티티 일관성 / 권위신호)
//     → 항목별 통과여부 + 구체적 수정안. 배포 시 백엔드가 URL 자동 fetch.
//
// 측정/분석=sonnet, 곁가지=haiku.

const MEASURE_MODEL = "claude-sonnet-4-20250514";
const HELPER_MODEL = "claude-haiku-4-5-20251001";

const SEGMENTS = {
  app: { label: "앱 · SaaS", sub: "모바일 앱·웹 서비스·툴", icon: "app", lens: "추천 순위",
    ph: { brand: "예: 우리가계부", category: "예: 가계부 앱 / 협업 툴" }, fit: "딱 맞음" },
  shop: { label: "D2C · 쇼핑몰", sub: "자사몰·브랜드·스마트스토어", icon: "bag", lens: "카테고리 순위",
    ph: { brand: "예: 코코로지", category: "예: 비건 토너 / 캠핑 의자" }, fit: "잘 맞음" },
  b2b: { label: "B2B · 전문 서비스", sub: "솔루션·에이전시·전문직", icon: "store", lens: "추천 순위",
    ph: { brand: "예: ○○컨설팅", category: "예: B2B 세무 SaaS / 브랜딩 에이전시" }, fit: "잘 맞음" },
};

const ENGINES = [
  { id: "chatgpt", name: "ChatGPT", tier: "free" },
  { id: "perplexity", name: "Perplexity", tier: "paid" },
  { id: "gemini", name: "Gemini", tier: "pro" },
];

// GEO 레시피 항목 (검색으로 확인한 표준)
const RECIPE = [
  { key: "directAnswer", label: "직접 답변", desc: "첫 40~60단어 안에 질문에 바로 답하는 문장이 있는가" },
  { key: "factDensity", label: "사실 밀도", desc: "150~200단어마다 구체적 수치·통계가 있는가" },
  { key: "schema", label: "스키마 마크업", desc: "구조화 데이터(FAQ·Product·Organization 등)가 있는가" },
  { key: "entity", label: "엔티티 일관성", desc: "브랜드명·서비스명이 일관되게 명시되는가" },
  { key: "authority", label: "권위 신호", desc: "출처 인용·전문성·신뢰 근거가 있는가" },
];

function cn(...c) { return c.filter(Boolean).join(" "); }
function parseList(raw) { return String(raw || "").split(/[,\n]/).map((x) => x.trim()).filter(Boolean); }
function norm(s) { return s.toLowerCase().replace(/\s/g, ""); }

async function callClaude(model, messages, { system, useTools } = {}) {
  const body = { model, max_tokens: 1500, messages };
  if (system) body.system = system;
  if (useTools) body.tools = [{ type: "web_search_20250305", name: "web_search", max_uses: 3 }];
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error("API " + res.status);
  return res.json();
}
function extractText(d) { return (d?.content || []).filter((b) => b.type === "text").map((b) => b.text).join("\n").trim(); }
function extractSources(d) {
  const u = new Set();
  for (const b of d?.content || []) {
    if (b.type === "text" && Array.isArray(b.citations)) b.citations.forEach((c) => c?.url && u.add(c.url));
    if (b.type === "web_search_tool_result" && Array.isArray(b.content)) b.content.forEach((r) => r?.url && u.add(r.url));
  }
  return [...u];
}
function parseJSON(t) { try { return JSON.parse(t.replace(/```json|```/g, "").trim()); } catch { return null; } }

// 노출 단계 판정 (언급/추천/인용)
async function classifyExposure(text, brand, sources) {
  const lower = text.toLowerCase(), b = brand.toLowerCase();
  if (!lower.includes(b)) return { level: "none", weight: 0 };
  // 인용: 출처 URL에 브랜드 흔적
  const cited = sources.some((u) => u.toLowerCase().includes(norm(brand)) || u.toLowerCase().includes(b.split(" ")[0]));
  if (cited) return { level: "citation", weight: 1.0 };
  // 추천 vs 단순언급: 소형 모델로 판정
  try {
    const d = await callClaude(HELPER_MODEL, [{ role: "user", content:
      `다음 AI 답변에서 "${brand}"가 (A)적극 추천/거명 추천 (B)스쳐가는 단순 언급 중 무엇인가? ` +
      `A 또는 B 한 글자만.\n\n${text.slice(0, 1500)}` }]);
    const r = extractText(d).toUpperCase();
    return r.includes("A") ? { level: "recommendation", weight: 0.7 } : { level: "mention", weight: 0.3 };
  } catch { return { level: "mention", weight: 0.3 }; }
}

async function extractNames(text, category) {
  try {
    const d = await callClaude(HELPER_MODEL, [{ role: "user", content:
      `다음 "${category}" 추천 답변에서 추천·언급된 실제 브랜드/제품/업체 고유명만 등장 순서대로 ` +
      `JSON 문자열 배열로. 코드블록 금지.\n\n${text.slice(0, 2000)}` }],
      { system: "너는 JSON 배열만 출력한다." });
    const arr = parseJSON(extractText(d));
    return Array.isArray(arr) ? arr.map(String).filter(Boolean) : [];
  } catch { return []; }
}

// GEO 레시피로 페이지 분석 (깊은 처방의 핵심)
async function analyzePage(pageText, brand, category) {
  if (!pageText || pageText.trim().length < 40) return null;
  try {
    const d = await callClaude(MEASURE_MODEL, [{ role: "user", content:
      `아래는 "${brand}"(${category})의 웹페이지 내용이다. GEO(생성형 엔진 최적화) 기준으로 평가하라.\n` +
      `각 항목을 pass/partial/fail로 판정하고, fail/partial이면 구체적 수정안을 한 문장으로.\n` +
      `항목: directAnswer(첫 40~60단어 내 직접 답변), factDensity(150~200단어마다 수치·통계), ` +
      `schema(구조화 데이터 존재 여부 추정), entity(브랜드·서비스명 일관 명시), authority(출처·전문성·신뢰 근거).\n` +
      `JSON으로만: {"directAnswer":{"status":"fail","fix":"..."},...,"summary":"한줄총평"}. 코드블록 금지.\n\n` +
      `=== 페이지 내용 ===\n${pageText.slice(0, 4000)}` }],
      { system: "너는 JSON만 출력하는 GEO 분석기다." });
    return parseJSON(extractText(d));
  } catch { return null; }
}

async function liveDiagnose({ lead, segment, competitors, pageText, tier, onProgress }) {
  const brand = lead.brand.trim(), category = lead.category.trim(), region = lead.region.trim();
  const activeEngines = ENGINES.filter((e) => tier === "pro" ? true : tier === "paid" ? e.tier !== "pro" : e.tier === "free");

  // 1) 질의어 생성 (haiku)
  onProgress?.("질문 생성");
  let prompts = [];
  try {
    const g = await callClaude(HELPER_MODEL, [{ role: "user", content:
      `${segment === "shop" ? "카테고리" : ""} "${category}"${region ? ` (${region})` : ""} 관련, 잠재고객이 ` +
      `AI 검색에 칠 추천형 한국어 질문 5개 + "${brand} 어때?" 1개. ` +
      `JSON 배열로만: [{"text":"...","type":"rec"}], 브랜드직접은 type:"brand". 코드블록 금지.` }],
      { system: "너는 JSON 배열만 출력한다." });
    const arr = parseJSON(extractText(g));
    if (Array.isArray(arr)) prompts = arr.filter((x) => x?.text).map((x) => ({ text: String(x.text), type: x.type || "rec" }));
  } catch {}
  if (!prompts.length) prompts = [
    { text: `${category} 추천해줘`, type: "rec" }, { text: `${category} 잘하는 곳`, type: "rec" },
    { text: `${category} 비교해줘`, type: "rec" }, { text: `${brand} 어때?`, type: "brand" },
  ];

  // 2) 측정 — 엔진별(데모는 동일 측정에 라벨, 배포 시 엔진별 실제 호출)
  const pool = {};
  function note(name, rank) { const k = name.trim(); if (!k) return; if (!pool[k]) pool[k] = { mentions: 0, rankSum: 0 }; pool[k].mentions++; pool[k].rankSum += rank; }
  const engineResults = {};
  const recPrompts = prompts.filter((p) => p.type === "rec");

  for (const eng of activeEngines) {
    onProgress?.(`${eng.name} 노출 측정`);
    let weightedSum = 0, count = 0, bestLevel = "none";
    const levelRank = { none: 0, mention: 1, recommendation: 2, citation: 3 };
    for (const p of prompts) {
      let text = "", sources = [], failed = false;
      try {
        const d = await callClaude(MEASURE_MODEL, [{ role: "user", content: p.text }], {
          useTools: true,
          system: `당신은 ${eng.name} 같은 AI 검색 어시스턴트입니다. 한국어로 실제 존재하는 브랜드·제품을 구체적으로 거명하며 추천하세요.`,
        });
        text = extractText(d); sources = extractSources(d);
      } catch { failed = true; }
      if (failed) continue;
      if (p.type === "rec") {
        const names = await extractNames(text, category);
        names.forEach((nm, idx) => note(nm, idx + 1));
        if (!names.some((nm) => norm(nm).includes(norm(brand))) && text.toLowerCase().includes(brand.toLowerCase())) note(brand, names.length + 1);
      }
      const exp = await classifyExposure(text, brand, sources);
      weightedSum += exp.weight; count++;
      if (levelRank[exp.level] > levelRank[bestLevel]) bestLevel = exp.level;
    }
    engineResults[eng.id] = { name: eng.name, tier: eng.tier, score: count ? Math.round((weightedSum / count) * 100) : 0, bestLevel };
  }

  // 3) 순위표 (rec 풀 기준, 엔진 통합)
  onProgress?.("순위 집계");
  const brandKey = Object.keys(pool).find((k) => norm(k).includes(norm(brand)) || norm(brand).includes(norm(k)));
  const ranking = Object.entries(pool).map(([name, v]) => ({
    name, mentions: v.mentions, avgRank: v.rankSum / v.mentions,
    self: brandKey ? name === brandKey : norm(name).includes(norm(brand)),
    isCompetitor: competitors.some((c) => norm(name).includes(norm(c)) || norm(c).includes(norm(name))),
  })).sort((a, b) => (b.mentions - a.mentions) || (a.avgRank - b.avgRank));
  ranking.forEach((r, i) => (r.rank = i + 1));
  const selfRow = ranking.find((r) => r.self);
  const totalPool = ranking.length;
  const myRank = selfRow ? selfRow.rank : null;

  // 4) 페이지 레시피 진단 (깊은 처방)
  let pageAudit = null;
  if (pageText && pageText.trim().length >= 40) {
    onProgress?.("페이지 GEO 진단");
    pageAudit = await analyzePage(pageText, brand, category);
  }

  // 5) 통합 점수 = 엔진 평균
  const engScores = Object.values(engineResults).map((e) => e.score);
  const score = engScores.length ? Math.round(engScores.reduce((a, b) => a + b, 0) / engScores.length) : 0;
  const grade = myRank == null ? "위험" : myRank <= Math.ceil(totalPool / 3) ? "양호" : myRank <= Math.ceil(totalPool * 2 / 3) ? "주의" : "위험";

  // 처방 우선순위 (페이지 진단 fail 항목 → 액션)
  let actions = [];
  if (pageAudit) {
    actions = RECIPE.filter((r) => pageAudit[r.key] && pageAudit[r.key].status !== "pass")
      .map((r) => pageAudit[r.key].fix).filter(Boolean);
  }
  if (actions.length < 3) {
    onProgress?.("처방 생성");
    try {
      const s = await callClaude(HELPER_MODEL, [{ role: "user", content:
        `"${category}" ${SEGMENTS[segment].label} "${brand}"가 AI 추천 ${myRank == null ? "권외" : myRank + "위"}. ` +
        `GEO 레시피(직접답변·사실밀도·스키마·엔티티·권위) 기준 상위 진입 실행 액션 5개, 각 한 줄 '- '.` }]);
      const more = extractText(s).split("\n").map((l) => l.replace(/^[-•*]\s?/, "").trim()).filter(Boolean);
      actions = [...actions, ...more].slice(0, 6);
    } catch {}
  }

  const topOccupants = ranking.filter((r) => !r.self).slice(0, 3);
  let summary;
  if (myRank == null) summary = `${category} AI 추천에서 "${brand}"가 거의 등장하지 않습니다. 인용 기반을 만드는 게 시급합니다.`;
  else if (myRank <= 3) summary = `${category} AI 추천 ${myRank}위로 상위권입니다. 인용 품질을 높여 격차를 벌릴 단계입니다.`;
  else summary = `${category} AI 추천 ${totalPool}곳 중 ${myRank}위입니다. 상위가 가진 인용 근거를 따라잡아야 합니다.`;

  return {
    segment, lens: SEGMENTS[segment].lens, tier, score, grade, myRank, totalPool,
    engineResults: Object.values(engineResults),
    ranking: ranking.slice(0, 12), topOccupants,
    pageAudit,
    riskSummary: summary,
    lockedDetails: {
      actions: actions.length ? actions : ["첫 문단을 40~60단어 직접답변으로 재작성", "FAQ 스키마 추가", "수치·근거를 본문 전반에 배치"],
      sources: [],
    },
    usage: {
      modelCalls: activeEngines.length * prompts.length + (pageAudit ? 1 : 0) + 3,
      webSearches: activeEngines.length * prompts.length,
      estimatedCostUsd: Math.round((activeEngines.length * prompts.length * 0.02 + (pageAudit ? 0.03 : 0) + 0.03) * 100) / 100,
      note: "측정·페이지진단은 상위 모델, 분류·요약은 소형 모델로 처리.",
    },
  };
}

export default function CiteRadarMVP() {
  const [step, setStep] = useState("form");
  const [segment, setSegment] = useState("app");
  const [tier, setTier] = useState("free");
  const [loading, setLoading] = useState(false);
  const [paidUnlocked, setPaidUnlocked] = useState(false);
  const [showCompetitor, setShowCompetitor] = useState(false);
  const [showCost, setShowCost] = useState(false);
  const [error, setError] = useState("");
  const [runLabel, setRunLabel] = useState("");
  const [lead, setLead] = useState({ brand: "", category: "", region: "", competitorsRaw: "" });
  const [pageText, setPageText] = useState("");
  const [result, setResult] = useState(null);

  const seg = SEGMENTS[segment];
  const competitors = useMemo(() => parseList(lead.competitorsRaw), [lead.competitorsRaw]);
  const canSubmit = lead.brand.trim() && lead.category.trim();
  const maxMentions = useMemo(() => Math.max(1, ...((result?.ranking || []).map((x) => x.mentions))), [result]);

  function updateField(k, v) { setLead((p) => ({ ...p, [k]: v })); }
  async function runDiagnosis() {
    setError("");
    if (!canSubmit) { setError("브랜드명과 카테고리를 입력하세요."); return; }
    setLoading(true); setStep("running");
    try {
      const data = await liveDiagnose({ lead, segment, competitors, pageText, tier, onProgress: setRunLabel });
      setResult(data); setStep("result");
    } catch (e) { setError(`진단 실패: ${e.message}`); setStep("form"); }
    finally { setLoading(false); }
  }
  function requestReport(p) { window.alert(p === "report" ? "상세 리포트 요청 접수" : "상담 요청 접수"); }

  const SegIcon = ({ name, size = 22 }) => name === "store" ? <Store size={size} /> : name === "bag" ? <ShoppingBag size={size} /> : <AppWindow size={size} />;
  const StatusIcon = ({ s }) => s === "pass" ? <CheckCircle2 size={18} className="ic-pass" /> : s === "partial" ? <MinusCircle size={18} className="ic-part" /> : <XCircle size={18} className="ic-fail" />;

  return (
    <div className="cr-root">
      <style>{CSS}</style>
      <div className="cr-wrap">
        <header className="cr-header">
          <div className="brand">
            <div className="brand-ico"><Radar size={24} /></div>
            <div><div className="brand-name">인용레이더</div><div className="brand-sub">AI 추천 진단 · 인용 최적화 처방</div></div>
          </div>
        </header>

        {error && <div className="cr-err fade-in">{error}</div>}

        {step === "form" && (
          <main className="cr-grid fade-up">
            <section className="card pad-lg">
              <div className="pill blue"><Sparkles size={14} /> 무료 진단</div>
              <h1 className="h1">AI가 왜 당신을 추천 안 하는지<br />페이지까지 열어 진단합니다</h1>
              <p className="lead">순위 측정에서 끝나지 않습니다. 당신 페이지가 GEO 레시피(직접답변·사실밀도·스키마·엔티티·권위) 중 뭐가 빠졌는지 짚고, 어떻게 고쳐야 인용되는지 처방합니다.</p>

              <div className="seg-grid">
                {Object.entries(SEGMENTS).map(([k, s]) => (
                  <button key={k} type="button" onClick={() => setSegment(k)} className={cn("seg-card", segment === k && "on")}>
                    <div className="seg-ico"><SegIcon name={s.icon} /></div>
                    <div className="seg-label">{s.label}</div>
                    <div className="seg-sub">{s.sub}</div>
                    <div className="seg-fit">LLM 적합도 · {s.fit}</div>
                  </button>
                ))}
              </div>

              <div className="stack">
                <div className="two">
                  <Field label="브랜드 / 서비스명" required value={lead.brand} onChange={(v) => updateField("brand", v)} placeholder={seg.ph.brand} />
                  <Field label="카테고리" required value={lead.category} onChange={(v) => updateField("category", v)} placeholder={seg.ph.category} />
                </div>

                {/* 깊은 처방의 핵심 입력 */}
                <label className="block">
                  <span className="lbl"><FileSearch size={14} className="inl" /> 내 페이지 내용 붙여넣기 <span className="opt-mark">(깊은 처방용)</span></span>
                  <textarea className="ta tall" value={pageText} onChange={(e) => setPageText(e.target.value)}
                    placeholder="홈페이지·소개·랜딩 페이지의 본문 텍스트를 붙여넣으면, GEO 레시피로 실제 분석해 '무엇이 빠졌는지' 콕 집어 처방합니다. (비워두면 일반 처방)" />
                  <span className="field-note">* 배포 버전에선 URL만 넣으면 자동으로 페이지를 가져와 분석합니다.</span>
                </label>

                <div>
                  <button type="button" className="opt-toggle" onClick={() => setShowCompetitor((x) => !x)}>
                    <ChevronRight className={cn("chev", showCompetitor && "open")} size={16} /> 경쟁사 직접 지정 (선택)
                  </button>
                  {showCompetitor && <textarea className="ta mt" value={lead.competitorsRaw} onChange={(e) => updateField("competitorsRaw", e.target.value)} placeholder="콕 집어 비교할 경쟁사" />}
                </div>

                {/* 단계적 멀티 LLM */}
                <div className="tier-box">
                  <div className="tier-lbl">측정할 AI 엔진</div>
                  <div className="tier-opts">
                    {[["free", "ChatGPT", "무료"], ["paid", "+ Perplexity", "리포트"], ["pro", "+ Gemini", "프로"]].map(([t, label, tag]) => (
                      <button key={t} type="button" onClick={() => setTier(t)} className={cn("tier-opt", tier === t && "on")}>
                        <span className="tier-name">{label}</span><span className="tier-tag">{tag}</span>
                      </button>
                    ))}
                  </div>
                </div>
              </div>

              <button onClick={runDiagnosis} disabled={!canSubmit || loading} className={cn("btn-primary full", !canSubmit && "disabled")}>
                무료로 진단 + 처방 받기 <ArrowRight size={19} />
              </button>
              <p className="micro">실제 AI 검색 + 페이지 분석을 수행합니다 (30초~1분).</p>
            </section>

            <aside className="stack">
              <div className="card pad just-card">
                <h3 className="h3">측정이 아니라 처방을 팝니다</h3>
                <p className="muted just-lead">"몇 위"는 누구나 압니다. 우리는 그다음을 줍니다.</p>
                <div className="flow">
                  {[["측정", "여러 AI에서 언급/추천/인용 3단계로"], ["진단", "내 페이지가 GEO 레시피 중 뭐가 빠졌나"], ["처방", "어떻게 고쳐야 인용되는가"], ["추적", "고친 뒤 순위가 오르는가"]].map(([t, d], i) => (
                    <div key={i} className="flow-item"><div className="flow-num">{i + 1}</div><div><div className="flow-t">{t}</div><div className="flow-d">{d}</div></div></div>
                  ))}
                </div>
              </div>
              <div className="card dark pad">
                <div className="ico-dark"><Wrench /></div>
                <h3 className="h3 white">SEO로는 안 됩니다</h3>
                <p className="muted-white">AI가 인용하는 출처의 10% 미만만 구글 상위에 듭니다. AI 인용은 완전히 다른 게임이고, 그 게임의 레시피로 당신 페이지를 고칩니다.</p>
              </div>
            </aside>
          </main>
        )}

        {step === "running" && <RunningView label={runLabel} />}

        {step === "result" && result && (
          <main className="stack-lg fade-up">
            <section className="card pad-lg">
              <div className="res-head">
                <div>
                  <div className={cn("pill", result.grade === "양호" ? "green" : result.grade === "주의" ? "amber" : "red")}>{result.grade} · {SEGMENTS[result.segment].label}</div>
                  <h2 className="h2">{lead.category} AI 추천 {result.lens}</h2>
                  <p className="sub">{lead.brand}</p>
                </div>
                <button onClick={() => setStep("form")} className="btn-ghost">다시 입력</button>
              </div>
              <div className="rank-hero">
                <div className="rank-badge">
                  {result.myRank == null ? <><div className="rank-out">권외</div><div className="rank-sub">추천 미등장</div></>
                    : <><div className="rank-num"><span className="rank-hash">#</span>{result.myRank}</div><div className="rank-sub">AI 추천 {result.totalPool}곳 중</div></>}
                </div>
                <p className="rank-summary">{result.riskSummary}</p>
              </div>
              {/* 엔진별 노출 */}
              <div className="eng-grid">
                {result.engineResults.map((e) => (
                  <div key={e.name} className="eng-card">
                    <div className="eng-name">{e.name}</div>
                    <div className="eng-score">{e.score}</div>
                    <div className={cn("eng-level", "lv-" + e.bestLevel)}>
                      {e.bestLevel === "citation" ? "인용됨" : e.bestLevel === "recommendation" ? "추천됨" : e.bestLevel === "mention" ? "언급만" : "미노출"}
                    </div>
                  </div>
                ))}
                {result.tier !== "pro" && (
                  <div className="eng-card locked-eng">
                    <Lock size={16} />
                    <div className="eng-locked-t">{result.tier === "free" ? "Perplexity·Gemini" : "Gemini"}</div>
                    <div className="eng-locked-s">상위 플랜</div>
                  </div>
                )}
              </div>
            </section>

            {/* 페이지 GEO 진단 — 깊은 처방의 핵심 */}
            {result.pageAudit ? (
              <section className="card pad audit">
                <h3 className="h3"><FileSearch size={18} className="inl" /> 내 페이지 GEO 진단</h3>
                <p className="muted sm-note">{result.pageAudit.summary}</p>
                <div className="recipe-list">
                  {RECIPE.map((r) => {
                    const a = result.pageAudit[r.key];
                    if (!a) return null;
                    return (
                      <div key={r.key} className={cn("recipe-row", "st-" + a.status)}>
                        <StatusIcon s={a.status} />
                        <div className="recipe-body">
                          <div className="recipe-top"><span className="recipe-label">{r.label}</span><span className={cn("recipe-stat", "ss-" + a.status)}>{a.status === "pass" ? "통과" : a.status === "partial" ? "부분" : "미흡"}</span></div>
                          <div className="recipe-desc">{r.desc}</div>
                          {a.status !== "pass" && a.fix && <div className="recipe-fix"><Wrench size={13} /> {a.fix}</div>}
                        </div>
                      </div>
                    );
                  })}
                </div>
              </section>
            ) : (
              <section className="card pad audit-empty">
                <h3 className="h3"><FileSearch size={18} className="inl" /> 내 페이지 GEO 진단</h3>
                <p className="muted">페이지 내용을 넣지 않아 일반 처방만 제공됩니다. <b>입력 화면에서 페이지 본문을 붙여넣으면</b>, 직접답변·스키마·엔티티 등 항목별로 "당신 페이지에 뭐가 빠졌는지"를 콕 집어 진단합니다.</p>
              </section>
            )}

            <section className="card pad">
              <h3 className="h3">AI 추천 {result.lens} 순위표</h3>
              <p className="muted sm-note">AI 답변에 등장한 브랜드를 언급 빈도·순서로 정렬. (AI가 실제 추천하는 풀 기준)</p>
              <div className="rank-list">
                {result.ranking.map((r) => (
                  <div key={r.name} className={cn("rank-row", r.self && "self", r.isCompetitor && "comp")}>
                    <div className="rank-pos">{r.rank}</div>
                    <div className="rank-name"><span className="trunc">{r.name}</span>{r.self && <span className="self-tag">우리</span>}{r.isCompetitor && !r.self && <span className="comp-tag">경쟁사</span>}</div>
                    <div className="rank-bar"><div className={cn("rank-fill", r.self && "self")} style={{ width: `${(r.mentions / maxMentions) * 100}%` }} /></div>
                    <div className="rank-cnt">{r.mentions}회</div>
                  </div>
                ))}
              </div>
            </section>

            <LockedReport result={result} paidUnlocked={paidUnlocked} onUnlock={() => setPaidUnlocked(true)} />

            <section className="three-col">
              <ProductCard icon={<FileText />} title="상세 리포트" price="149,000원" desc="페이지 항목별 수정안 전문, 상위 인용 출처, 다중 AI 비교, PDF" button="리포트 요청" featured onClick={() => requestReport("report")} />
              <ProductCard icon={<RefreshCcw />} title="월간 모니터링" price="월 290,000원" desc="고친 뒤 순위가 오르는지 매월 추적. 다중 AI 추세 보고." button="월 관리 상담" onClick={() => requestReport("monthly")} />
              <ProductCard icon={<Wrench />} title="개선 대행" price="월 500,000원~" desc="처방받은 항목(콘텐츠·스키마·엔티티)을 직접 고쳐 드립니다." button="대행 문의" onClick={() => requestReport("managed")} />
            </section>

            <section className="card pad-sm">
              <button onClick={() => setShowCost((x) => !x)} className="cost-toggle">내부용 API 원가 보기<ChevronRight className={cn("chev", showCost && "open")} size={18} /></button>
              {showCost && (<div className="cost-grid">
                <MiniBox label="모델 호출" value={`${result.usage.modelCalls}회`} />
                <MiniBox label="웹검색" value={`${result.usage.webSearches}회`} />
                <MiniBox label="예상 원가" value={`$${result.usage.estimatedCostUsd}`} />
                <p className="cost-note">{result.usage.note}</p>
              </div>)}
            </section>
          </main>
        )}
      </div>
    </div>
  );
}

function Field({ label, value, onChange, placeholder, required }) {
  return (<label className="block"><span className="lbl">{label} {required && <span className="req">*</span>}</span>
    <input className="inp" value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder} /></label>);
}
function RunningView({ label }) {
  const steps = ["질문 생성", "엔진별 노출 측정", "순위·페이지 진단", "처방 생성"];
  return (<section className="card pad-lg center fade-up">
    <div className="run-ico"><div className="spin"><Radar size={42} /></div></div>
    <h2 className="h2">진단하고 처방을 만들고 있어요</h2>
    <p className="lead center-text">AI 추천을 측정하고, 당신 페이지를 GEO 레시피로 분석합니다.</p>
    {label && <p className="run-label">{label}</p>}
    <div className="run-steps">{steps.map((x, i) => (<div key={x} className="run-step" style={{ animationDelay: `${i * 0.15}s` }}>{x}</div>))}</div>
  </section>);
}
function LockedReport({ result, paidUnlocked, onUnlock }) {
  return (<section className="card dark pad-lg">
    <div className="lock-head">
      <div><div className="pill ghost-white"><Lock size={14} /> 유료 리포트</div>
        <h3 className="h2 white">전체 수정안 + 다중 AI 비교</h3>
        <p className="muted-white">무료는 진단·핵심 처방, 리포트는 항목별 수정 전문과 상위 인용 출처를 공개합니다.</p></div>
      {!paidUnlocked && <button onClick={onUnlock} className="btn-white">데모 잠금해제</button>}
    </div>
    {!paidUnlocked ? (
      <div className="three-col">
        <LockedTile title="항목별 수정안 전문" desc="페이지 각 부분을 어떻게 고칠지" />
        <LockedTile title="상위 인용 출처" desc="1위가 인용된 사이트 유형" />
        <LockedTile title="다중 AI 비교" desc="ChatGPT vs Perplexity vs Gemini" />
      </div>
    ) : (
      <div className="three-col">
        <UnlockedTile title="우선순위 처방" items={result.lockedDetails.actions} />
        <UnlockedTile title="상위 인용 출처" items={["(유료) 상위 브랜드가 인용된 출처 유형 분석", "블로그·비교글·커뮤니티 등 채널별"]} />
        <UnlockedTile title="다중 AI 비교" items={result.engineResults.map((e) => `${e.name}: ${e.score}점 · ${e.bestLevel === "citation" ? "인용" : e.bestLevel === "recommendation" ? "추천" : e.bestLevel === "mention" ? "언급" : "미노출"}`)} />
      </div>
    )}
  </section>);
}
function LockedTile({ title, desc }) { return (<div className="lock-tile"><h4 className="tile-h">{title}</h4><p className="tile-blur">{desc}<br />리포트 구매 후 확인</p><div className="tile-overlay"><span className="lock-badge">잠금</span></div></div>); }
function UnlockedTile({ title, items }) { return (<div className="unlock-tile"><h4 className="tile-h">{title}</h4><div className="tile-items">{items.map((it, i) => <p key={i}>• {it}</p>)}</div></div>); }
function ProductCard({ icon, title, price, desc, button, onClick, featured }) {
  return (<div className={cn("prod", featured && "feat")}><div className={cn("prod-ico", featured && "feat-ico")}>{icon}</div><h3 className="h3">{title}</h3><div className={cn("prod-price", featured && "feat-price")}>{price}</div><p className={cn("prod-desc", featured && "feat-desc")}>{desc}</p><button onClick={onClick} className={cn("prod-btn", featured && "feat-btn")}>{button} <ArrowRight size={16} /></button></div>);
}
function MiniBox({ label, value }) { return <div className="mini"><div className="mini-lbl">{label}</div><div className="mini-val">{value}</div></div>; }

const CSS = `
@import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+KR:wght@400;500;700&display=swap');
*{box-sizing:border-box;margin:0;padding:0}
.cr-root{--bg:#F7F8FA;--ink:#191F28;--ink2:#333D4B;--ink3:#4E5968;--dim:#6B7684;--dim2:#8B95A1;
  --line:#E5E8EB;--soft:#F2F4F6;--soft2:#F9FAFB;--blue:#3182F6;--blue2:#1B64DA;--bluebg:#EAF2FE;
  --amber:#D97706;--amberbg:#FEF3C7;--green:#0F9D58;--greenbg:#E3F6EC;--red:#E5484D;--redbg:#FDEDEE;
  background:var(--bg);color:var(--ink);min-height:100%;font-family:'IBM Plex Sans KR',sans-serif;-webkit-font-smoothing:antialiased}
.cr-wrap{max-width:1120px;margin:0 auto;padding:20px}
@media(min-width:640px){.cr-wrap{padding:32px}}
@keyframes fadeUp{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:none}}
@keyframes fadeIn{from{opacity:0}to{opacity:1}}
.fade-up{animation:fadeUp .4s ease both}.fade-in{animation:fadeIn .3s ease both}
.cr-header{display:flex;align-items:center;gap:16px;margin-bottom:24px}
.brand{display:flex;align-items:center;gap:12px}
.brand-ico{width:44px;height:44px;border-radius:14px;background:var(--blue);color:#fff;display:flex;align-items:center;justify-content:center;box-shadow:0 12px 28px rgba(49,130,246,.25)}
.brand-name{font-size:20px;font-weight:700;letter-spacing:-.04em}
.brand-sub{font-size:12px;color:var(--dim2);font-weight:500}
.cr-grid{display:grid;gap:24px}
@media(min-width:1024px){.cr-grid{grid-template-columns:1.05fr .95fr}}
.stack{display:flex;flex-direction:column;gap:16px}
.stack-lg{display:flex;flex-direction:column;gap:24px}
.two{display:grid;gap:16px}@media(min-width:640px){.two{grid-template-columns:1fr 1fr}}
.three-col{display:grid;gap:16px}@media(min-width:768px){.three-col{grid-template-columns:1fr 1fr 1fr}}
.card{background:#fff;border-radius:28px;box-shadow:0 18px 50px rgba(25,31,40,.06)}
.card.dark{background:var(--ink);color:#fff;box-shadow:0 18px 50px rgba(25,31,40,.18)}
.pad{padding:24px}.pad-lg{padding:24px}.pad-sm{padding:20px}@media(min-width:640px){.pad-lg{padding:32px}}
.pill{display:inline-flex;align-items:center;gap:6px;padding:6px 12px;border-radius:999px;font-size:12px;font-weight:700;margin-bottom:12px}
.pill.blue{background:var(--bluebg);color:var(--blue)}.pill.amber{background:var(--amberbg);color:var(--amber)}
.pill.green{background:var(--greenbg);color:var(--green)}.pill.red{background:var(--redbg);color:var(--red)}
.pill.ghost-white{background:rgba(255,255,255,.1);color:rgba(255,255,255,.75)}
.h1{font-size:26px;font-weight:800;letter-spacing:-.04em;line-height:1.28}@media(min-width:640px){.h1{font-size:31px}}
.h2{font-size:24px;font-weight:800;letter-spacing:-.04em}
.h3{font-size:18px;font-weight:800;letter-spacing:-.03em}
.inl{vertical-align:-3px;margin-right:5px;color:var(--blue)}
.white{color:#fff}
.lead{margin-top:14px;max-width:32rem;font-size:15px;line-height:1.7;color:var(--dim)}
.sub{margin-top:8px;font-size:14px;color:var(--dim)}
.sm-note{margin-top:6px;margin-bottom:16px;font-size:12.5px;line-height:1.6}
.seg-grid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:10px;margin:20px 0 24px}
.seg-card{text-align:left;border:1.5px solid var(--line);background:var(--soft2);border-radius:18px;padding:14px;cursor:pointer;transition:.15s;font-family:inherit}
.seg-card:hover{border-color:var(--dim2)}
.seg-card.on{border-color:var(--blue);background:var(--bluebg);box-shadow:0 0 0 3px rgba(49,130,246,.12)}
.seg-ico{width:36px;height:36px;border-radius:10px;background:#fff;color:var(--blue);display:flex;align-items:center;justify-content:center;margin-bottom:10px}
.seg-card.on .seg-ico{background:var(--blue);color:#fff}
.seg-label{font-size:14px;font-weight:800}
.seg-sub{font-size:11px;color:var(--dim2);margin-top:2px;line-height:1.4}
.seg-fit{margin-top:8px;font-size:11px;font-weight:700;color:var(--green)}
.block{display:block}
.lbl{display:block;margin-bottom:8px;font-size:14px;font-weight:700;color:var(--ink2)}
.req{color:var(--blue)}.opt-mark{color:var(--dim2);font-weight:600;font-size:12px}
.inp,.ta{width:100%;border:1px solid var(--line);background:var(--soft2);border-radius:16px;padding:14px 18px;font-size:15px;font-family:inherit;color:var(--ink);outline:none;transition:.15s}
.ta{min-height:80px;resize:vertical;border-radius:18px}.ta.tall{min-height:130px}.mt{margin-top:12px}
.inp:focus,.ta:focus{border-color:var(--blue);background:#fff;box-shadow:0 0 0 4px var(--bluebg)}
.inp::placeholder,.ta::placeholder{color:#B0B8C1}
.field-note{display:block;margin-top:6px;font-size:11.5px;color:var(--dim2)}
.opt-toggle{display:flex;align-items:center;gap:6px;border:none;background:none;padding:0;font-size:13px;font-weight:600;color:var(--dim);cursor:pointer;font-family:inherit}
.chev{transition:transform .2s;flex-shrink:0}.chev.open{transform:rotate(90deg)}
.tier-box{background:var(--soft2);border-radius:18px;padding:16px}
.tier-lbl{font-size:13px;font-weight:700;color:var(--ink2);margin-bottom:10px}
.tier-opts{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px}
.tier-opt{border:1.5px solid var(--line);background:#fff;border-radius:12px;padding:10px 8px;cursor:pointer;font-family:inherit;display:flex;flex-direction:column;gap:3px;align-items:center;transition:.15s}
.tier-opt.on{border-color:var(--blue);background:var(--bluebg)}
.tier-name{font-size:12.5px;font-weight:800;color:var(--ink)}
.tier-tag{font-size:10px;font-weight:700;color:var(--dim2)}
.tier-opt.on .tier-tag{color:var(--blue)}
.btn-primary{margin-top:24px;width:100%;display:flex;align-items:center;justify-content:center;gap:8px;border:none;background:var(--blue);color:#fff;border-radius:16px;padding:16px;font-size:16px;font-weight:800;font-family:inherit;cursor:pointer;transition:.15s;box-shadow:0 14px 30px rgba(49,130,246,.25)}
.btn-primary:hover{background:var(--blue2)}.btn-primary.disabled{background:var(--line);color:var(--dim2);box-shadow:none;cursor:not-allowed}
.full{width:100%}.micro{margin-top:10px;font-size:12px;color:var(--dim2);text-align:center}
.just-lead{margin-top:4px;margin-bottom:16px;font-size:13.5px}
.flow{display:flex;flex-direction:column;gap:14px}
.flow-item{display:flex;gap:12px;align-items:flex-start}
.flow-num{width:28px;height:28px;border-radius:9px;background:var(--bluebg);color:var(--blue);display:flex;align-items:center;justify-content:center;font-weight:800;font-size:13px;flex-shrink:0}
.flow-t{font-size:14px;font-weight:800}
.flow-d{font-size:12.5px;color:var(--dim);margin-top:1px;line-height:1.5}
.ico-dark{width:48px;height:48px;border-radius:16px;background:rgba(255,255,255,.1);display:flex;align-items:center;justify-content:center;margin-bottom:20px}
.muted{margin-top:4px;font-size:14px;line-height:1.6;color:var(--dim)}
.muted-white{margin-top:12px;font-size:14px;line-height:1.6;color:rgba(255,255,255,.65)}
.cr-err{margin-bottom:20px;border:1px solid #FAD4D6;background:var(--redbg);color:var(--red);padding:16px 20px;border-radius:16px;font-size:14px;font-weight:600}
.center{text-align:center}.center-text{margin-left:auto;margin-right:auto}
.run-ico{width:96px;height:96px;border-radius:28px;background:var(--bluebg);color:var(--blue);display:flex;align-items:center;justify-content:center;margin:0 auto 28px}
.spin{display:flex;animation:spin 1.4s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}
.run-label{margin-top:16px;font-size:14px;font-weight:700;color:var(--blue)}
.run-steps{max-width:42rem;margin:28px auto 0;display:grid;gap:12px}@media(min-width:640px){.run-steps{grid-template-columns:repeat(4,1fr)}}
.run-step{background:var(--soft);padding:12px 16px;border-radius:14px;font-size:14px;font-weight:700;color:var(--ink3);animation:pulse 1.8s ease infinite}
@keyframes pulse{0%,100%{opacity:.45}50%{opacity:1}}
.res-head{display:flex;flex-direction:column;gap:16px;margin-bottom:24px}
@media(min-width:640px){.res-head{flex-direction:row;align-items:flex-start;justify-content:space-between}}
.btn-ghost{align-self:flex-start;border:none;background:var(--soft);color:var(--ink3);padding:12px 16px;border-radius:14px;font-size:14px;font-weight:700;cursor:pointer;font-family:inherit;transition:.15s}
.btn-ghost:hover{background:var(--line)}
.rank-hero{display:flex;flex-direction:column;gap:20px;align-items:center;text-align:center;background:linear-gradient(135deg,var(--blue),#4A90F7);border-radius:24px;padding:32px 24px;color:#fff;margin-bottom:20px}
@media(min-width:640px){.rank-hero{flex-direction:row;text-align:left;gap:28px}}
.rank-badge{flex-shrink:0;min-width:140px}
.rank-num{font-size:72px;font-weight:800;letter-spacing:-.06em;line-height:1;display:flex;align-items:flex-start;justify-content:center;gap:2px}
@media(min-width:640px){.rank-num{justify-content:flex-start}}
.rank-hash{font-size:36px;margin-top:6px;opacity:.8}
.rank-out{font-size:48px;font-weight:800;letter-spacing:-.04em}
.rank-sub{font-size:14px;font-weight:600;color:rgba(255,255,255,.8);margin-top:4px}
.rank-summary{font-size:15px;line-height:1.7;color:rgba(255,255,255,.92);background:rgba(255,255,255,.12);padding:18px;border-radius:18px}
.eng-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:12px}
.eng-card{background:var(--soft2);border-radius:18px;padding:16px;text-align:center}
.eng-name{font-size:13px;font-weight:800;color:var(--ink2)}
.eng-score{font-size:32px;font-weight:800;letter-spacing:-.04em;margin:4px 0}
.eng-level{font-size:11px;font-weight:800;padding:3px 10px;border-radius:999px;display:inline-block}
.lv-citation{background:var(--greenbg);color:var(--green)}.lv-recommendation{background:var(--bluebg);color:var(--blue)}
.lv-mention{background:var(--amberbg);color:var(--amber)}.lv-none{background:var(--redbg);color:var(--red)}
.locked-eng{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px;color:var(--dim2);border:1.5px dashed var(--line);background:#fff}
.eng-locked-t{font-size:12px;font-weight:800;color:var(--ink3)}.eng-locked-s{font-size:11px}
.audit{border:2px solid var(--blue)}
.recipe-list{display:flex;flex-direction:column;gap:10px}
.recipe-row{display:flex;gap:12px;padding:14px;border-radius:16px;background:var(--soft2)}
.recipe-row.st-fail{background:var(--redbg)}.recipe-row.st-partial{background:var(--amberbg)}
.ic-pass{color:var(--green);flex-shrink:0;margin-top:1px}.ic-part{color:var(--amber);flex-shrink:0;margin-top:1px}.ic-fail{color:var(--red);flex-shrink:0;margin-top:1px}
.recipe-body{flex:1;min-width:0}
.recipe-top{display:flex;align-items:center;gap:8px;margin-bottom:2px}
.recipe-label{font-size:14px;font-weight:800;color:var(--ink)}
.recipe-stat{font-size:11px;font-weight:800;padding:2px 8px;border-radius:999px}
.ss-pass{background:var(--greenbg);color:var(--green)}.ss-partial{background:#fff;color:var(--amber)}.ss-fail{background:#fff;color:var(--red)}
.recipe-desc{font-size:12.5px;color:var(--dim);line-height:1.5}
.recipe-fix{margin-top:8px;font-size:13px;font-weight:600;color:var(--ink2);background:#fff;padding:10px 12px;border-radius:12px;display:flex;gap:7px;align-items:flex-start;line-height:1.5}
.recipe-fix svg{color:var(--blue);flex-shrink:0;margin-top:2px}
.audit-empty{border:1.5px dashed var(--line)}
.rank-list{display:flex;flex-direction:column;gap:8px}
.rank-row{display:grid;grid-template-columns:36px 1fr 100px 48px;align-items:center;gap:12px;padding:10px 12px;border-radius:14px;background:var(--soft2)}
.rank-row.self{background:var(--bluebg);box-shadow:0 0 0 2px var(--blue) inset}
.rank-row.comp{background:#FFF4E6}
.rank-pos{font-size:16px;font-weight:800;color:var(--dim);text-align:center}
.rank-row.self .rank-pos{color:var(--blue)}
.rank-name{display:flex;align-items:center;gap:8px;min-width:0;font-weight:700;color:var(--ink2);font-size:14px}
.self-tag{background:var(--blue);color:#fff;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:800;flex-shrink:0}
.comp-tag{background:var(--amber);color:#fff;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;flex-shrink:0}
.trunc{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.rank-bar{height:8px;background:var(--line);border-radius:999px;overflow:hidden}
.rank-fill{height:100%;background:#B0B8C1;border-radius:999px;transition:width .8s ease}.rank-fill.self{background:var(--blue)}
.rank-cnt{font-size:12px;font-weight:700;color:var(--dim2);text-align:right}
.lock-head{display:flex;flex-direction:column;gap:16px;margin-bottom:24px}
@media(min-width:640px){.lock-head{flex-direction:row;align-items:center;justify-content:space-between}}
.btn-white{align-self:flex-start;border:none;background:#fff;color:var(--ink);padding:12px 16px;border-radius:14px;font-size:14px;font-weight:800;cursor:pointer;font-family:inherit}
.lock-tile{position:relative;overflow:hidden;border-radius:20px;background:rgba(255,255,255,.08);padding:20px}
.tile-h{font-weight:800}
.tile-blur{margin-top:8px;font-size:14px;line-height:1.6;color:rgba(255,255,255,.45);filter:blur(2px)}
.tile-overlay{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;background:rgba(25,31,40,.3)}
.lock-badge{background:#fff;color:var(--ink);padding:4px 12px;border-radius:999px;font-size:12px;font-weight:800}
.unlock-tile{border-radius:20px;background:rgba(255,255,255,.08);padding:20px}
.tile-items{margin-top:16px;display:flex;flex-direction:column;gap:12px;font-size:14px;line-height:1.6;color:rgba(255,255,255,.65)}
.prod{background:#fff;border-radius:24px;padding:24px;box-shadow:0 18px 50px rgba(25,31,40,.06)}
.prod.feat{background:var(--blue);color:#fff}
.prod-ico{width:48px;height:48px;border-radius:16px;background:var(--bluebg);color:var(--blue);display:flex;align-items:center;justify-content:center;margin-bottom:20px}
.prod-ico.feat-ico{background:rgba(255,255,255,.15);color:#fff}
.prod-price{margin-top:8px;font-size:28px;font-weight:800;letter-spacing:-.05em;color:var(--blue)}.prod-price.feat-price{color:#fff}
.prod-desc{margin-top:16px;min-height:68px;font-size:14px;line-height:1.6;color:var(--dim)}.prod-desc.feat-desc{color:rgba(255,255,255,.72)}
.prod-btn{margin-top:20px;width:100%;display:flex;align-items:center;justify-content:center;gap:8px;border:none;background:var(--soft);color:var(--ink2);border-radius:14px;padding:12px;font-size:14px;font-weight:800;cursor:pointer;font-family:inherit;transition:.15s}
.prod-btn:hover{background:var(--line)}.prod-btn.feat-btn{background:#fff;color:var(--blue)}
.cost-toggle{width:100%;display:flex;align-items:center;justify-content:space-between;border:none;background:none;font-size:14px;font-weight:800;color:var(--ink3);cursor:pointer;font-family:inherit;text-align:left}
.cost-grid{margin-top:20px;display:grid;gap:12px;grid-template-columns:1fr 1fr}@media(min-width:1024px){.cost-grid{grid-template-columns:repeat(3,1fr)}}
.mini{background:var(--soft2);border-radius:14px;padding:16px}
.mini-lbl{font-size:12px;font-weight:700;color:var(--dim2)}.mini-val{margin-top:4px;font-size:18px;font-weight:800;color:var(--ink2)}
.cost-note{font-size:12px;line-height:1.5;color:var(--dim2);grid-column:1/-1}
@media(max-width:560px){.seg-grid{grid-template-columns:1fr}.tier-opts{grid-template-columns:1fr}.rank-row{grid-template-columns:28px 1fr 64px 38px;gap:8px}}
`;
