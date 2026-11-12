// 虎整组句资格测试（tiger_engine_set_segment_policy，对齐虎整 HEAD
// auto_select_min_code_length=3 / high_freq_limit=1500）：
//   - 码长 ≥3 的非首选单字可省选重键参与组句并按分数竞争（孑@rfi 次选：
//     rfiil → 孑立、lwanlwanrfiil → 茕茕孑立），2 码非首选仍挡（皿@am）；
//   - 高频字非最优码（词表 h 标记，书@aag）不进组句段，整段单打不受影响；
//   - 0/0 保持旧定顶；all_ranks=1（魔虎）不受该设置影响；
//   - 增量/退格解码与全新解码逐候选一致（整段→段边的身份切换）。
// 用真实 V5 模型 + 仓库虎整词表；缺资产时 skip。TIGER_NGRAM /
// TIGER_LEXICON 可覆盖路径。
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "tigerengine.h"

namespace {

std::string env_or(const char* name, const std::string& fallback) {
  const char* value = getenv(name);
  return value && *value ? value : fallback;
}

std::vector<std::string> decode_candidates(int handle, const char* raw, size_t limit = 20) {
  static char out[1 << 22];
  const int rc = tiger_decode(handle, raw, 0, out, sizeof(out), nullptr);
  if (rc <= 0) return {};
  std::vector<std::string> texts;
  const char* p = out;
  const char* line_end = strchr(p, '\n');
  if (!line_end) return {};
  p = line_end + 1;
  while (*p && texts.size() < limit) {
    line_end = strchr(p, '\n');
    if (!line_end) line_end = p + strlen(p);
    const char* tab = static_cast<const char*>(memchr(p, '\t', line_end - p));
    if (!tab) break;
    texts.emplace_back(p, tab - p);
    if (!*line_end) break;
    p = line_end + 1;
  }
  return texts;
}

bool contains(const std::vector<std::string>& items, const std::string& want) {
  for (const std::string& item : items)
    if (item == want) return true;
  return false;
}

int failures = 0;

void expect(bool ok, const char* what) {
  if (ok) {
    printf("pass: %s\n", what);
  } else {
    printf("fail: %s\n", what);
    ++failures;
  }
}

std::string first(const std::vector<std::string>& items) {
  return items.empty() ? std::string() : items[0];
}

int create(const std::string& model, const std::string& lexicon, int all_ranks) {
  char error[512] = {};
  const int h = tiger_engine_create(model.c_str(), lexicon.c_str(), 200, all_ranks,
                                    error, sizeof(error));
  if (h < 0) {
    printf("fail: engine create: %s\n", error);
    exit(1);
  }
  tiger_engine_set_two_char_word_gate(h, 0);
  return h;
}

// 逐键（含退格）增量解码 h，与每步先清缓存再全量解码的 fresh 比对。
void expect_incremental_matches_fresh(int h, int fresh, const std::vector<std::string>& steps,
                                      const char* what) {
  bool ok = true;
  for (const std::string& raw : steps) {
    const std::vector<std::string> incremental = decode_candidates(h, raw.c_str());
    decode_candidates(fresh, "q");  // 单键输入不复用，下一次必为全量重建
    const std::vector<std::string> full = decode_candidates(fresh, raw.c_str());
    if (incremental != full) {
      printf("  mismatch at %s: incremental=%s fresh=%s\n", raw.c_str(),
             first(incremental).c_str(), first(full).c_str());
      ok = false;
    }
  }
  expect(ok, what);
}

}  // namespace

int main() {
  const std::string model = env_or("TIGER_NGRAM", "tiger_sentence_native/mohu-sentence-ngram-v5.bin");
  const std::string lexicon = env_or("TIGER_LEXICON", "tiger_sentence_native/data/tiger/tiger.lexicon.txt");
  for (const std::string* path : {&model, &lexicon}) {
    FILE* probe = fopen(path->c_str(), "rb");
    if (!probe) {
      printf("skip: %s not found\n", path->c_str());
      return 0;
    }
    fclose(probe);
  }

  const int h = create(model, lexicon, 0);

  // 旧定顶（未设置 = 0/0）：段边只取首选。
  std::vector<std::string> legacy = decode_candidates(h, "rfiil");
  expect(first(legacy) == "韭立" && !contains(legacy, "孑立"), "legacy: rfiil keeps rank-1 only");

  expect(tiger_engine_set_segment_policy(h, 3, 1) == 1, "set policy 3/1 applies");
  expect(tiger_engine_set_segment_policy(h, 3, 1) == 0, "same policy reports no change");
  expect(tiger_engine_set_segment_policy(h, -1, 0) == -1 &&
         tiger_engine_set_segment_policy(h, 129, 0) == -1 &&
         tiger_engine_set_segment_policy(h, 3, 2) == -1,
         "out-of-range policy rejected");

  expect(first(decode_candidates(h, "rfiil")) == "孑立", "rfiil: 3-key non-first 孑 composes first");
  expect(first(decode_candidates(h, "lwanlwanrfiil")) == "茕茕孑立",
         "lwanlwanrfiil: 茕茕孑立 first");
  const std::vector<std::string> whole = decode_candidates(h, "rfi");
  expect(whole.size() >= 2 && whole[0] == "韭" && whole[1] == "孑",
         "rfi whole input keeps lexicon order");

  // 码长门槛：2 码非首选单字（皿@am）只在门槛 ≤2 时放行。
  expect(!contains(decode_candidates(h, "amil"), "皿立"), "2-key non-first 皿 blocked at min 3");
  tiger_engine_set_segment_policy(h, 2, 1);
  expect(contains(decode_candidates(h, "amil"), "皿立"), "2-key non-first 皿 allowed at min 2");

  // 高频字非最优码：书 最优码 aa，aag 不作句中段；单打 aag 仍出 书。
  tiger_engine_set_segment_policy(h, 3, 1);
  expect(!contains(decode_candidates(h, "aagil"), "书立"), "high-freq filter blocks 书@aag in segments");
  expect(first(decode_candidates(h, "aag")) == "书", "high-freq filter keeps whole-input 书@aag");
  tiger_engine_set_segment_policy(h, 3, 0);
  expect(contains(decode_candidates(h, "aagil"), "书立"), "filter off restores 书@aag in segments");

  // 增量与退格：整段命中边（rfi=孑 次选、aag=书）随输入增长变成段边。
  tiger_engine_set_segment_policy(h, 3, 1);
  const int fresh = create(model, lexicon, 0);
  tiger_engine_set_segment_policy(fresh, 3, 1);
  expect_incremental_matches_fresh(
      h, fresh,
      {"rf", "rfi", "rfii", "rfiil", "rfiila", "rfiilaa", "rfiilaag", "rfiilaagi",
       "rfiilaagil", "rfiilaagi", "rfiilaag", "rfiilaa", "rfiil", "rfii", "rfi"},
      "incremental and backspace decode match fresh decode");
  // ≤4 键内复用：am 整段边放行 皿（次选），续打 il 后 am 变段边，皿 不得漏进。
  expect_incremental_matches_fresh(h, fresh, {"q", "am", "ami", "amil", "ami", "am"},
                                   "whole-input rank-2 state is not reused as a segment");

  // all_ranks=1（魔虎）不受该设置影响。
  const int free_engine = create(model, lexicon, 1);
  const std::vector<std::string> before = decode_candidates(free_engine, "rfiilaagil");
  tiger_engine_set_segment_policy(free_engine, 3, 1);
  decode_candidates(free_engine, "q");
  expect(decode_candidates(free_engine, "rfiilaagil") == before, "all_ranks=1 ignores segment policy");

  tiger_engine_free(free_engine);
  tiger_engine_free(fresh);
  tiger_engine_free(h);
  if (failures) {
    printf("%d failure(s)\n", failures);
    return 1;
  }
  printf("segment policy tests passed\n");
  return 0;
}
