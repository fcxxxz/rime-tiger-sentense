#!/usr/bin/env python3
"""构建「虎码·整句」独立安装包 zip（布局镜像魔虎发行包；模型不随包，
用户从 Release 下载放入 mohu/model/）。用法: python3 make_dist.py [输出目录=dist]"""
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / 'dist'
STAGE = OUT / 'tiger-sentence'

# 2026-11-11 瘦身：zrm/flypy 双拼运行库（.words 240万行 ×2、其 sentence_core
# 编译钩子、custom_phrases）不随虎包——虎方案单独安装时 words 永不编译，
# 纯占 65MB 包体的大头；双拼整句装魔虎主包。2026-11-12 起反查走引擎模型
# 解码（tiger_rev_engine.lua，无词库）：mohu_pinyin/mohu_rev_* 全部退役，
# 双拼 lexicon 随包分发（zrm 17M + flypy 16M，zip 后 ~10M；全拼模式 lua
# 层切音节复用 zrm lexicon，无独立数据）。
ROOT_FILES = [
    'LICENSE', 'README.md', 'default.yaml', 'punctuation.yaml', 'symbols.yaml',
    'key_bindings.yaml', 'mohu.yaml', 'mohu_defs.yaml',
    'tiger.schema.yaml', 'tiger.dict.yaml', 'tiger.extended.dict.yaml', 'tiger.user.dict.yaml',
    'mohu_charset.dict.yaml', 'mohu_charset.schema.yaml',
]
DIRS = ['lua', 'opencc']
RUNTIME = [
    ('tiger_sentence_native/libtigerengine.dylib', 'mohu/runtime/libtigerengine.dylib'),
    ('tiger_sentence_native/data/tiger/tiger.lexicon.txt', 'mohu/data/tiger/tiger.lexicon.txt'),
    ('tiger_sentence_native/data/zrm/mohu_zrm.lexicon.txt', 'mohu/data/zrm/mohu_zrm.lexicon.txt'),
    ('tiger_sentence_native/data/flypy/mohu_flypy.lexicon.txt', 'mohu/data/flypy/mohu_flypy.lexicon.txt'),
    # 整句 lua 三件套（shim → 引擎适配 → runtime 路径解析）；缺任一则
    # schema 静默回退单字模式（2026-11-11 装机实测踩过）。
    ('tiger_sentence_native/mohu_sentence.lua', 'lua/mohu_sentence.lua'),
    ('tiger_sentence_native/mohu_tiger_sentence.lua', 'lua/mohu_tiger_sentence.lua'),
    ('tiger_sentence_native/mohu_runtime.lua', 'lua/mohu_runtime.lua'),
]


def main() -> None:
    missing = [n for n in ROOT_FILES if not (ROOT / n).exists()]
    if missing:
        raise SystemExit(f'missing files: {missing}')
    for src, _ in RUNTIME:
        if not (ROOT / src).exists():
            raise SystemExit(f'missing runtime file: {src}')

    import shutil
    if STAGE.exists():
        shutil.rmtree(STAGE)
    STAGE.mkdir(parents=True)
    for name in ROOT_FILES:
        shutil.copy2(ROOT / name, STAGE / name)
    for d in DIRS:
        shutil.copytree(ROOT / d, STAGE / d,
                        ignore=shutil.ignore_patterns('__pycache__', '.DS_Store'))
    for src, rel in RUNTIME:
        target = STAGE / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / src, target)
    # 模型目录预建（README 指引下载 V5 放入）；config 为 user-ngram.snapshot 父目录
    (STAGE / 'mohu/model').mkdir()
    (STAGE / 'mohu/model/把 mohu-sentence-ngram-v5.bin 放到这里.txt').write_text(
        '从 Release 下载 mohu-sentence-ngram-v5.bin 放入本目录后重新部署。\n', encoding='utf-8')
    (STAGE / 'mohu/config').mkdir()

    zip_path = OUT / 'tiger-sentence-latest.zip'
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for p in sorted(STAGE.rglob('*')):
            zf.write(p, p.relative_to(OUT))
    sha = subprocess.check_output(['shasum', '-a', '256', str(zip_path)], text=True).split()[0]
    print(f'{zip_path}  {zip_path.stat().st_size:,} bytes  sha256={sha}')


if __name__ == '__main__':
    main()
