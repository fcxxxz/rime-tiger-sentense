# 虎码·整句 独立仓 Makefile（自魔虎仓精简迁出，2026-11-10）
# 只保留整句引擎测试与构建；码表再生成/打包机器不随仓（见 PROVENANCE.md）。

# dylib 按 Lua 5.4 ABI 构建（Squirrel 同源）；系统 lua 若是 5.5 会
# version mismatch，优先用 homebrew lua@5.4，缺失时回退 PATH 里的 lua。
MOHU_LUA_BIN ?= $(shell test -x /opt/homebrew/opt/lua@5.4/bin/lua && echo /opt/homebrew/opt/lua@5.4/bin/lua || echo lua)
TIGER_NGRAM ?= tiger_sentence_native/mohu-sentence-ngram-v5.bin
TIGER_ENGINE_INCLUDES = -I tiger_sentence_native
UNAME_S := $(shell uname -s)
ifeq ($(OS),Windows_NT)
TIGER_EXTRA_LDFLAGS =
else
TIGER_EXTRA_LDFLAGS = -framework Accelerate
endif

.PHONY: all test lua-tests tigerengine-native tigerengine-safety tigerengine-lua-safety \
	tigerengine-static-compact tigerengine-early-learning tigerengine-context \
	tigerengine-learning-context tigerengine-mapping tigerengine-mobile \
	tigerengine-personal-internal tigerengine-reading-prior tigerengine-snapshot-io \
	tigerengine-user-model tigerengine-word-edge tigerengine-word-form \
	tigerengine-word-score tigerengine-word-units tigerengine-aux-words

all: test

# ---- 引擎构建（仅 macOS 重编；dylib 已随仓提交，其他平台直接消费） ----
tigerengine-native: tiger_sentence_native/tigerengine.cc tiger_sentence_native/tigerengine_lua.cc tiger_sentence_native/tigerengine.h
ifeq ($(UNAME_S),Darwin)
	@test -f tiger_sentence_native/lua-5.4.6/src/lua.hpp || \
		(echo "Lua 5.4 headers are required; see tiger_sentence_native/README.md" >&2; exit 1)
	zsh tiger_sentence_native/build.sh
else
	@test -f tiger_sentence_native/libtigerengine.dylib || \
		(echo "Error: engine rebuild is macOS-only; commit libtigerengine.dylib or build on macOS" >&2; exit 1)
	@echo "tigerengine-native: non-macOS host, using committed libtigerengine.dylib"
endif

# ---- C++ 引擎测试 ----
tigerengine-safety:
	clang++ -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) tests/tigerengine_safety_test.cc tiger_sentence_native/tigerengine.cc $(TIGER_EXTRA_LDFLAGS) -o /tmp/tigerengine_safety_test
	/tmp/tigerengine_safety_test

tigerengine-lua-safety:
	@if [ -f tiger_sentence_native/lua-5.4.6/src/liblua.a ]; then \
		clang++ -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) -I tiger_sentence_native/lua-5.4.6/src \
			tests/tigerengine_lua_safety_test.cc tiger_sentence_native/tigerengine.cc \
			tiger_sentence_native/tigerengine_lua.cc tiger_sentence_native/lua-5.4.6/src/liblua.a \
			-lm -ldl $(TIGER_EXTRA_LDFLAGS) -o /tmp/tigerengine_lua_safety_test; \
		/tmp/tigerengine_lua_safety_test; \
	else \
		echo "tigerengine Lua safety tests skipped (Lua 5.4 static library not present)"; \
	fi

tigerengine-context:
	clang++ -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) tests/tigerengine_context_test.cc \
		tiger_sentence_native/tigerengine.cc $(TIGER_EXTRA_LDFLAGS) -o /tmp/tigerengine_context_test
	/tmp/tigerengine_context_test

tigerengine-learning-context:
	clang++ -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) tests/tigerengine_learning_context_test.cc \
		tiger_sentence_native/tigerengine.cc $(TIGER_EXTRA_LDFLAGS) -o /tmp/tigerengine_learning_context_test
	/tmp/tigerengine_learning_context_test

tigerengine-mapping:
	@mkdir -p .tmp/native-tests
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -std=c++17 -O2 -DTIGERENGINE_MAPPING_TEST \
		$(TIGER_ENGINE_INCLUDES) tests/tigerengine_mapping_ownership_test.cc \
		tiger_sentence_native/tigerengine.cc -o .tmp/native-tests/tigerengine_mapping_ownership_test
	.tmp/native-tests/tigerengine_mapping_ownership_test

tigerengine-mobile:
	@mkdir -p .tmp/native-tests
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) \
		tests/tigerengine_mobile_test.cc tiger_sentence_native/tigerengine.cc \
		-o .tmp/native-tests/tigerengine_mobile_test
	python3 tests/tigerengine_mobile_cases.py .tmp/native-tests/tigerengine_mobile_test

tigerengine-personal-internal:
	clang++ -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) tests/tigerengine_personal_internal_test.cc \
		tiger_sentence_native/tigerengine.cc $(TIGER_EXTRA_LDFLAGS) -o /tmp/tigerengine_personal_internal_test
	/tmp/tigerengine_personal_internal_test

tigerengine-reading-prior:
	clang++ -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) tests/tigerengine_reading_prior_test.cc \
		tiger_sentence_native/tigerengine.cc $(TIGER_EXTRA_LDFLAGS) -o /tmp/tigerengine_reading_prior_test
	/tmp/tigerengine_reading_prior_test

tigerengine-snapshot-io:
	@mkdir -p .tmp/native-tests
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) \
		tests/tigerengine_snapshot_io_test.cc tiger_sentence_native/tigerengine.cc \
		-o .tmp/native-tests/tigerengine_snapshot_io_test
	.tmp/native-tests/tigerengine_snapshot_io_test

tigerengine-user-model:
	clang++ -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) tests/tigerengine_user_model_test.cc \
		tiger_sentence_native/tigerengine.cc $(TIGER_EXTRA_LDFLAGS) -o /tmp/tigerengine_user_model_test
	/tmp/tigerengine_user_model_test

tigerengine-word-edge:
	clang++ -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) tests/tigerengine_word_edge_test.cc \
		tiger_sentence_native/tigerengine.cc $(TIGER_EXTRA_LDFLAGS) -o /tmp/tigerengine_word_edge_test
	/tmp/tigerengine_word_edge_test

tigerengine-word-form:
	clang++ -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) tests/tigerengine_word_form_test.cc \
		tiger_sentence_native/tigerengine.cc $(TIGER_EXTRA_LDFLAGS) -o /tmp/tigerengine_word_form_test
	/tmp/tigerengine_word_form_test

tigerengine-word-score:
	clang++ -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) tests/tigerengine_word_score_test.cc \
		tiger_sentence_native/tigerengine.cc $(TIGER_EXTRA_LDFLAGS) -o /tmp/tigerengine_word_score_test
	/tmp/tigerengine_word_score_test

tigerengine-word-units:
	clang++ -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) tests/tigerengine_word_units_test.cc \
		tiger_sentence_native/tigerengine.cc $(TIGER_EXTRA_LDFLAGS) -o /tmp/tigerengine_word_units_test
	/tmp/tigerengine_word_units_test

tigerengine-aux-words:
	clang++ -std=c++17 -O2 $(TIGER_ENGINE_INCLUDES) tests/tigerengine_aux_words_test.cc \
		$(TIGER_EXTRA_LDFLAGS) -o /tmp/tigerengine_aux_words_test
	/tmp/tigerengine_aux_words_test

# ---- 真实模型上的 Lua 引擎测试（模型 gitignore，需先放入本仓路径） ----
tigerengine-static-compact: tigerengine-native
	$(MOHU_LUA_BIN) tests/tiger_static_compact_test.lua "$(CURDIR)"

tigerengine-early-learning: tigerengine-native
	$(MOHU_LUA_BIN) tests/tiger_early_learning_native_test.lua "$(CURDIR)" whole
	$(MOHU_LUA_BIN) tests/tiger_early_learning_native_test.lua "$(CURDIR)" tail

# ---- Lua 单测全套（魔虎框架 + 虎码整句；各自内部缺资产自动跳过） ----
lua-tests:
	@set -e; for t in tests/*_test.lua; do \
		echo "== $$t"; \
		$(MOHU_LUA_BIN) "$$t" "$(CURDIR)" || { echo "FAIL $$t"; exit 1; }; \
	done

# ---- 汇总 ----
test: lua-tests tigerengine-safety tigerengine-lua-safety tigerengine-static-compact \
	tigerengine-early-learning tigerengine-context tigerengine-learning-context \
	tigerengine-mapping tigerengine-mobile tigerengine-personal-internal \
	tigerengine-reading-prior tigerengine-snapshot-io tigerengine-user-model \
	tigerengine-word-edge tigerengine-word-form tigerengine-word-score \
	tigerengine-word-units tigerengine-aux-words
	@echo "ALL TESTS PASSED"
