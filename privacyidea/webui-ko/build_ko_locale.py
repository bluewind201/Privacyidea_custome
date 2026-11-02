#!/usr/bin/env python3
"""privacyIDEA WebUI 한국어(ko) 번들 생성기 (이미지 빌드 시 실행)

privacyIDEA 는 Angular 로 빌드된 WebUI 를 언어별 폴더(browser/en, browser/de, ...)로
배포하며, 언어별 번들은 같은 코드에 번역 문자열만 다르게 들어 있다. 한국어는 공식 번역이
없으므로 다음과 같이 만든다.

  1. en 번들과 de(및 보조 언어) 번들을 같은 방식으로 토큰화해 위치를 맞춘다.
     값이 다른 문자열 = 번역 대상 문자열이다. (코드는 건드리지 않음)
  2. 그 위치의 영어 문자열을 ko.json 의 한국어로 바꿔 browser/ko 를 만든다.
     번역이 없는 문자열은 영어로 남는다.
  3. ko 번들의 $localize.locale 을 "ko" 로 바꾸고 Angular 의 ko 로캘 데이터를 등록한다.
  4. 모든 언어 번들의 언어 선택 목록에 "한국어" 를 추가한다.

privacyIDEA 버전이 바뀌어 구조가 달라지면 조용히 깨지지 않도록 빌드를 실패시킨다.

  5. (선택) 테마 CSS 를 모든 언어 번들에 연결한다. 여러 파일을 주면 순서대로 합친다.

사용법: build_ko_locale.py <browser 디렉터리> <ko.json> <angular-locale-ko.js> [theme.css ...]
"""
import json
import os
import re
import shutil
import sys

MIN_TRANSLATED_RATIO = 0.8   # 번역 대상 위치 중 이 비율 이상이 바뀌지 않으면 실패
REF_LOCALES = ("de", "pl", "da", "lo")   # 번역 위치 비교용 (de 필수)
LANG_ENTRY_EN = '{code:"en",label:"English"},'
LANG_ENTRY_KO = '{code:"ko",label:"\\uD55C\\uAD6D\\uC5B4"},'


def tokenize(s):
    """문자열 리터럴('...', "...", `...`)과 그 사이 코드로 나눈다.
    완벽한 JS 파서는 아니지만 en/de 번들에 똑같이 적용되므로 위치는 항상 일치한다."""
    out, buf, i, n = [], [], 0, len(s)
    while i < n:
        c = s[i]
        if c in "'\"`":
            q, j = c, i + 1
            while j < n:
                if s[j] == "\\":
                    j += 2
                    continue
                if s[j] == q:
                    break
                if q == "`" and s[j] == "$" and j + 1 < n and s[j + 1] == "{":
                    depth, j = 1, j + 2
                    while j < n and depth:
                        if s[j] == "{":
                            depth += 1
                        elif s[j] == "}":
                            depth -= 1
                        j += 1
                    continue
                j += 1
            out.append(("c", "".join(buf)))
            buf = []
            out.append(("s", s[i:j + 1]))
            i = j + 1
        else:
            buf.append(c)
            i += 1
    out.append(("c", "".join(buf)))
    return out


def js_escape(text):
    """한국어 등 비ASCII 문자를 \\uXXXX 로 바꿔 어떤 따옴표 안에서도 안전하게 만든다."""
    res = []
    for ch in text:
        cp = ord(ch)
        if cp < 0x80:
            res.append(ch)
        elif cp <= 0xFFFF:
            res.append("\\u%04X" % cp)
        else:
            cp -= 0x10000
            res.append("\\u%04X\\u%04X" % (0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF)))
    return "".join(res)


def unescaped_quotes(s):
    return {c for c in "'\"`" if re.search(r"(?<!\\)" + re.escape(c), s)}


def safe(key, value):
    """번역문이 원문에 없던 따옴표/이스케이프/템플릿 표현식을 만들지 않는지 확인."""
    if not unescaped_quotes(value) <= unescaped_quotes(key):
        return False
    if value.count("${") != key.count("${"):
        return False
    if any(e not in key for e in re.findall(r"\\.", value)):
        return False
    return not value.endswith("\\")


def aligned(ta, tb):
    return len(ta) == len(tb) and all(x[0] == y[0] for x, y in zip(ta, tb))


def translate_file(en_text, ref_texts, ko_map, stats):
    """ref_texts[0] 은 de (필수), 나머지는 보조 비교 언어 (정렬될 때만 사용).
    de 와 같은 단어(예: Dashboard, Token)도 다른 언어에서 번역되어 있으면 대상이 된다."""
    ta = tokenize(en_text)
    refs = [tokenize(t) for t in ref_texts]
    if not aligned(ta, refs[0]):
        raise SystemExit("[ko] en/de 번들 구조가 달라 정렬할 수 없습니다 (privacyIDEA 버전 확인 필요)")
    refs = [r for r in refs if aligned(ta, r)]
    out = []
    for i, (kind, en_tok) in enumerate(ta):
        if any(r[i][1] != en_tok for r in refs):
            stats["targets"] += 1
            raw = en_tok[1:-1] if kind == "s" else en_tok
            ko = ko_map.get(raw)
            if ko is not None and safe(raw, ko):
                ko = js_escape(ko)
                en_tok = en_tok[0] + ko + en_tok[-1] if kind == "s" else ko
                stats["translated"] += 1
        out.append(en_tok)
    return "".join(out)


def add_language_entry(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if LANG_ENTRY_KO in text:
        return True
    if text.count(LANG_ENTRY_EN) != 1:
        return False
    with open(path, "w", encoding="utf-8") as f:
        f.write(text.replace(LANG_ENTRY_EN, LANG_ENTRY_EN + LANG_ENTRY_KO, 1))
    return True


def main():
    browser, ko_json, ng_locale = sys.argv[1:4]
    theme_css = sys.argv[4:]
    en, ko = os.path.join(browser, "en"), os.path.join(browser, "ko")
    with open(ko_json, encoding="utf-8") as f:
        ko_map = json.load(f)

    if os.path.exists(ko):
        shutil.rmtree(ko)
    shutil.copytree(en, ko)

    stats = {"targets": 0, "translated": 0}
    js_files = sorted(f for f in os.listdir(en) if f.endswith(".js"))
    for name in js_files:
        if name.startswith("polyfills-"):
            continue
        with open(os.path.join(en, name), encoding="utf-8") as f:
            en_text = f.read()
        refs = []
        for loc in REF_LOCALES:
            path = os.path.join(browser, loc, name)
            if os.path.isfile(path):
                with open(path, encoding="utf-8") as f:
                    refs.append(f.read())
            elif loc == "de":
                raise SystemExit(f"[ko] de 번들에 {name} 이(가) 없습니다")
        if all(r == en_text for r in refs):
            continue
        with open(os.path.join(ko, name), "w", encoding="utf-8") as f:
            f.write(translate_file(en_text, refs, ko_map, stats))

    ratio = stats["translated"] / max(stats["targets"], 1)
    print(f"[ko] 번역 대상 {stats['targets']} 곳 중 {stats['translated']} 곳 번역 ({ratio:.0%})")
    if ratio < MIN_TRANSLATED_RATIO:
        raise SystemExit("[ko] 번역 비율이 너무 낮습니다. privacyIDEA 버전에 맞게 ko.json 을 갱신하세요.")

    # polyfills: Angular ko 로캘 데이터 등록 + $localize.locale = "ko"
    poly = [f for f in js_files if f.startswith("polyfills-")]
    if len(poly) != 1:
        raise SystemExit("[ko] polyfills 파일을 찾을 수 없습니다")
    p = os.path.join(ko, poly[0])
    with open(p, encoding="utf-8") as f:
        text = f.read()
    marker = '.locale="en";'
    if text.count(marker) != 1:
        raise SystemExit("[ko] $localize.locale 설정을 찾을 수 없습니다")
    with open(ng_locale, encoding="utf-8") as f:
        locale_data = f.read()
    text = text.replace(marker, '.locale="ko";', 1) + "\n" + locale_data
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)

    # index.html
    idx = os.path.join(ko, "index.html")
    with open(idx, encoding="utf-8") as f:
        html = f.read()
    if '/browser/en/' not in html or 'lang="en"' not in html:
        raise SystemExit("[ko] index.html 형식이 예상과 다릅니다")
    html = html.replace("/browser/en/", "/browser/ko/").replace('lang="en"', 'lang="ko"', 1)
    with open(idx, "w", encoding="utf-8") as f:
        f.write(html)

    # 모든 언어 번들의 언어 선택 목록에 한국어 추가
    patched = 0
    for loc in sorted(os.listdir(browser)):
        d = os.path.join(browser, loc)
        if not os.path.isfile(os.path.join(d, "index.html")):
            continue
        for name in os.listdir(d):
            if name.endswith(".js") and add_language_entry(os.path.join(d, name)):
                patched += 1
                break
    if patched == 0:
        raise SystemExit("[ko] 언어 선택 목록을 찾을 수 없습니다")
    print(f"[ko] 언어 선택 목록에 한국어 추가: {patched} 개 번들")

    if theme_css:
        install_theme(browser, theme_css)


THEME_FILE = "pi-theme.css"


def install_theme(browser, css_files):
    """테마 CSS 파일들을 하나로 합쳐 모든 언어 번들에 복사하고 index.html 의 원본 스타일 뒤에 연결한다.
    같은 출처(self)의 파일이므로 Nginx CSP(style-src 'self')를 바꿀 필요가 없다."""
    css = []
    for path in css_files:
        with open(path, encoding="utf-8") as f:
            css.append(f.read())
    css = "\n".join(css)
    count = 0
    for loc in sorted(os.listdir(browser)):
        d = os.path.join(browser, loc)
        idx = os.path.join(d, "index.html")
        if not os.path.isfile(idx):
            continue
        with open(os.path.join(d, THEME_FILE), "w", encoding="utf-8") as f:
            f.write(css)
        with open(idx, encoding="utf-8") as f:
            html = f.read()
        link = f'<link rel="stylesheet" href="{THEME_FILE}">'
        if link not in html:
            if "</head>" not in html:
                raise SystemExit(f"[theme] {loc}/index.html 에 </head> 가 없습니다")
            html = html.replace("</head>", link + "</head>", 1)
            with open(idx, "w", encoding="utf-8") as f:
                f.write(html)
        count += 1
    print(f"[theme] 테마 적용 ({len(css_files)} 개 CSS): {count} 개 번들")


if __name__ == "__main__":
    main()
