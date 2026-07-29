(() => {
  "use strict";

  const note = document.querySelector("[data-why-story]");
  const content = document.querySelector("[data-why-story-content]");
  const tableOfContents = document.querySelector("[data-why-story-toc]");
  if (!note || !content || !tableOfContents) return;

  const supportedLocales = new Set([
    "ko",
    "en",
    "de",
    "es",
    "fr",
    "ja",
    "zh-Hans",
    "zh-Hant"
  ]);
  const storyDataRoot = "site-data/why-story";
  const copy = {
    en: {
      eyebrow: "FOUNDER'S NOTE · FULL TEXT",
      sectionLead: "The complete revised statement, presented as a readable note.",
      coverLabel: "ORIGIN / DOCUMENT",
      title: "Why ForgePlay Exists — Full Text",
      lead: "The complete revised statement, kept intact for close reading.",
      meta: "REVISED · 30 JUL 2026 · LONG READ",
      open: "Open the full note",
      close: "Close the full note",
      paperLabel: "FORGEPLAY / FOUNDER'S NOTE / 01",
      contents: "Contents",
      loading: "Opening the note…",
      error: "The full text could not be loaded. Please try again.",
      references: "Sources & notes",
      backToText: "Back to reference"
    },
    ko: {
      eyebrow: "제작자 노트 · 전문",
      sectionLead: "개정 선언문 전체를 읽기 편한 노트 형식으로 담았습니다.",
      coverLabel: "기원 / 문서",
      title: "왜 ForgePlay를 만들었는가 — 전문",
      lead: "생략하지 않은 개정 선언문을 차분히 읽을 수 있도록 정리했습니다.",
      meta: "개정본 · 2026년 7월 30일 · 긴 글",
      open: "전문 펼쳐보기",
      close: "전문 접기",
      paperLabel: "FORGEPLAY / 제작자 노트 / 01",
      contents: "목차",
      loading: "노트를 펼치는 중…",
      error: "전문을 불러오지 못했습니다. 잠시 후 다시 시도해 주세요.",
      references: "출처 및 주석",
      backToText: "본문 인용으로 돌아가기"
    },
    de: {
      eyebrow: "NOTIZ DES ENTWICKLERS · VOLLTEXT",
      sectionLead: "Die vollständige überarbeitete Erklärung als gut lesbare Notiz.",
      coverLabel: "URSPRUNG / DOKUMENT",
      title: "Warum ForgePlay existiert — Volltext",
      lead: "Die vollständige überarbeitete Erklärung, ungekürzt zum Nachlesen.",
      meta: "ÜBERARBEITET · 30. JULI 2026 · LANGTEXT",
      open: "Vollständige Notiz öffnen",
      close: "Vollständige Notiz schließen",
      paperLabel: "FORGEPLAY / NOTIZ DES ENTWICKLERS / 01",
      contents: "Inhalt",
      loading: "Notiz wird geöffnet…",
      error: "Der Volltext konnte nicht geladen werden. Bitte erneut versuchen.",
      references: "Quellen und Anmerkungen",
      backToText: "Zurück zur Textstelle"
    },
    es: {
      eyebrow: "NOTA DEL CREADOR · TEXTO COMPLETO",
      sectionLead: "La declaración revisada completa, presentada como una nota fácil de leer.",
      coverLabel: "ORIGEN / DOCUMENTO",
      title: "Por qué existe ForgePlay — Texto completo",
      lead: "La declaración revisada íntegra, sin recortes y preparada para una lectura pausada.",
      meta: "REVISADO · 30 JUL 2026 · LECTURA LARGA",
      open: "Abrir la nota completa",
      close: "Cerrar la nota completa",
      paperLabel: "FORGEPLAY / NOTA DEL CREADOR / 01",
      contents: "Contenido",
      loading: "Abriendo la nota…",
      error: "No se pudo cargar el texto completo. Inténtalo de nuevo.",
      references: "Fuentes y notas",
      backToText: "Volver a la referencia"
    },
    fr: {
      eyebrow: "NOTE DU CRÉATEUR · TEXTE INTÉGRAL",
      sectionLead: "La déclaration révisée dans son intégralité, présentée comme une note agréable à lire.",
      coverLabel: "ORIGINE / DOCUMENT",
      title: "Pourquoi ForgePlay existe — Texte intégral",
      lead: "La déclaration révisée complète, sans coupe, pour une lecture attentive.",
      meta: "RÉVISÉ · 30 JUIL. 2026 · LECTURE LONGUE",
      open: "Ouvrir la note intégrale",
      close: "Fermer la note intégrale",
      paperLabel: "FORGEPLAY / NOTE DU CRÉATEUR / 01",
      contents: "Sommaire",
      loading: "Ouverture de la note…",
      error: "Le texte intégral n’a pas pu être chargé. Veuillez réessayer.",
      references: "Sources et notes",
      backToText: "Revenir à la référence"
    },
    ja: {
      eyebrow: "制作者ノート・全文",
      sectionLead: "改訂した宣言文の全文を、読みやすいノート形式で掲載します。",
      coverLabel: "原点 / 文書",
      title: "ForgePlayをつくった理由 — 全文",
      lead: "省略のない改訂版を、落ち着いて読める形にまとめました。",
      meta: "改訂版・2026年7月30日・長文",
      open: "全文を開く",
      close: "全文を閉じる",
      paperLabel: "FORGEPLAY / 制作者ノート / 01",
      contents: "目次",
      loading: "ノートを開いています…",
      error: "全文を読み込めませんでした。もう一度お試しください。",
      references: "出典と注記",
      backToText: "本文の参照箇所に戻る"
    },
    "zh-Hans": {
      eyebrow: "创作者手记 · 全文",
      sectionLead: "以便于阅读的笔记形式，完整呈现修订后的宣言。",
      coverLabel: "起点 / 文档",
      title: "为何打造ForgePlay — 全文",
      lead: "修订版宣言全文，不作删节，供你细读。",
      meta: "修订版 · 2026年7月30日 · 长文",
      open: "展开全文",
      close: "收起全文",
      paperLabel: "FORGEPLAY / 创作者手记 / 01",
      contents: "目录",
      loading: "正在展开手记…",
      error: "无法加载全文，请稍后重试。",
      references: "来源与注释",
      backToText: "返回正文引用处"
    },
    "zh-Hant": {
      eyebrow: "創作者手記 · 全文",
      sectionLead: "以便於閱讀的筆記形式，完整呈現修訂後的宣言。",
      coverLabel: "起點 / 文件",
      title: "為何打造ForgePlay — 全文",
      lead: "修訂版宣言全文，不作刪節，供你細讀。",
      meta: "修訂版 · 2026年7月30日 · 長文",
      open: "展開全文",
      close: "收起全文",
      paperLabel: "FORGEPLAY / 創作者手記 / 01",
      contents: "目錄",
      loading: "正在展開手記…",
      error: "無法載入全文，請稍後再試。",
      references: "來源與註釋",
      backToText: "返回正文引用處"
    }
  };

  const markdownCache = new Map();
  let renderedLocale = null;
  let renderSequence = 0;

  const locale = () => {
    const value = window.ForgePlaySite?.getLocale()
      || document.documentElement.lang
      || "en";
    return supportedLocales.has(value) ? value : "en";
  };

  const text = (selectedLocale, key) => (
    copy[selectedLocale]?.[key] || copy.en[key] || ""
  );

  const applyInterfaceCopy = (selectedLocale) => {
    document.querySelectorAll("[data-why-story-i18n]").forEach((element) => {
      const value = text(selectedLocale, element.dataset.whyStoryI18n);
      if (value) element.textContent = value;
    });
    document.querySelectorAll("[data-why-story-i18n-aria-label]").forEach((element) => {
      const value = text(
        selectedLocale,
        element.dataset.whyStoryI18nAriaLabel
      );
      if (value) element.setAttribute("aria-label", value);
    });
  };

  const appendInline = (parent, source, context) => {
    const pattern = /(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\(https?:\/\/[^)]+\)|\[\^[^\]]+\])/g;
    let cursor = 0;
    for (const match of source.matchAll(pattern)) {
      if (match.index > cursor) {
        parent.append(document.createTextNode(source.slice(cursor, match.index)));
      }
      const token = match[0];
      if (token.startsWith("**")) {
        const strong = document.createElement("strong");
        strong.textContent = token.slice(2, -2);
        parent.append(strong);
      } else if (token.startsWith("`")) {
        const code = document.createElement("code");
        code.textContent = token.slice(1, -1);
        parent.append(code);
      } else if (token.startsWith("[^")) {
        const identifier = token.slice(2, -1);
        const reference = context.references.get(identifier);
        if (reference) {
          const backReferences = context.backReferences.get(identifier) || [];
          const backReference = `${context.prefix}-back-${identifier}-${backReferences.length + 1}`;
          backReferences.push(backReference);
          context.backReferences.set(identifier, backReferences);
          const superscript = document.createElement("sup");
          const link = document.createElement("a");
          link.id = backReference;
          link.href = `#${context.prefix}-ref-${identifier}`;
          link.textContent = String(reference.index);
          superscript.append(link);
          parent.append(superscript);
        } else {
          parent.append(document.createTextNode(token));
        }
      } else {
        const boundary = token.indexOf("](");
        const label = token.slice(1, boundary);
        const href = token.slice(boundary + 2, -1);
        const link = document.createElement("a");
        link.href = href;
        link.target = "_blank";
        link.rel = "noopener noreferrer";
        link.textContent = label;
        parent.append(link);
      }
      cursor = match.index + token.length;
    }
    if (cursor < source.length) {
      parent.append(document.createTextNode(source.slice(cursor)));
    }
  };

  const renderMarkdown = (markdown, selectedLocale) => {
    const lines = markdown.replace(/\r\n?/g, "\n").split("\n");
    const references = new Map();
    lines.forEach((line) => {
      const match = line.match(/^\[\^([^\]]+)\]:\s*(.+)$/);
      if (!match || references.has(match[1])) return;
      references.set(match[1], {
        index: references.size + 1,
        content: match[2]
      });
    });

    const prefix = `why-note-${selectedLocale.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`;
    const context = { prefix, references, backReferences: new Map() };
    const fragment = document.createDocumentFragment();
    const tocFragment = document.createDocumentFragment();
    let sectionIndex = 0;

    const isBlockStart = (line) => (
      /^(#{2,4})\s+/.test(line)
      || /^>\s?/.test(line)
      || /^-\s+/.test(line)
      || /^\[\^[^\]]+\]:\s*/.test(line)
    );

    for (let index = 0; index < lines.length;) {
      const line = lines[index];
      if (!line.trim() || /^\[\^[^\]]+\]:\s*/.test(line)) {
        index += 1;
        continue;
      }

      const heading = line.match(/^(#{2,4})\s+(.+)$/);
      if (heading) {
        const level = heading[1].length === 2 ? 2 : 3;
        const element = document.createElement(`h${level}`);
        appendInline(element, heading[2], context);
        if (level === 3) {
          sectionIndex += 1;
          element.id = `${prefix}-section-${sectionIndex}`;
          const link = document.createElement("a");
          link.href = `#${element.id}`;
          link.dataset.index = String(sectionIndex).padStart(2, "0");
          link.textContent = element.textContent;
          tocFragment.append(link);
        }
        fragment.append(element);
        index += 1;
        continue;
      }

      if (/^>\s?/.test(line)) {
        const quote = document.createElement("blockquote");
        while (index < lines.length && /^>\s?/.test(lines[index])) {
          const paragraph = document.createElement("p");
          appendInline(paragraph, lines[index].replace(/^>\s?/, "").trim(), context);
          quote.append(paragraph);
          index += 1;
        }
        fragment.append(quote);
        continue;
      }

      if (/^-\s+/.test(line)) {
        const list = document.createElement("ul");
        while (index < lines.length && /^-\s+/.test(lines[index])) {
          const item = document.createElement("li");
          appendInline(item, lines[index].replace(/^-\s+/, "").trim(), context);
          list.append(item);
          index += 1;
        }
        fragment.append(list);
        continue;
      }

      const paragraphLines = [];
      while (
        index < lines.length
        && lines[index].trim()
        && !isBlockStart(lines[index])
      ) {
        paragraphLines.push(lines[index].trim());
        index += 1;
      }
      if (paragraphLines.length) {
        const paragraph = document.createElement("p");
        appendInline(paragraph, paragraphLines.join(" "), context);
        fragment.append(paragraph);
      } else {
        index += 1;
      }
    }

    if (references.size) {
      const referenceSection = document.createElement("section");
      referenceSection.className = "founder-note-references";
      const heading = document.createElement("h3");
      heading.textContent = text(selectedLocale, "references");
      referenceSection.append(heading);
      const list = document.createElement("ol");
      references.forEach((reference, identifier) => {
        const item = document.createElement("li");
        item.id = `${prefix}-ref-${identifier}`;
        appendInline(item, reference.content, context);
        const backReferences = context.backReferences.get(identifier) || [];
        backReferences.forEach((backReference, index) => {
          const backLink = document.createElement("a");
          backLink.className = "founder-note-backref";
          backLink.href = `#${backReference}`;
          backLink.setAttribute("aria-label", text(selectedLocale, "backToText"));
          backLink.textContent = backReferences.length > 1 ? `↩${index + 1}` : "↩";
          item.append(backLink);
        });
        list.append(item);
      });
      referenceSection.append(list);
      fragment.append(referenceSection);
    }

    return { fragment, tocFragment };
  };

  const fetchMarkdown = async (selectedLocale) => {
    if (markdownCache.has(selectedLocale)) {
      return markdownCache.get(selectedLocale);
    }
    const url = new URL(
      `${storyDataRoot}/${encodeURIComponent(selectedLocale)}.md`,
      document.baseURI
    );
    url.searchParams.set("refresh", Date.now().toString());
    const response = await fetch(url, {
      cache: "no-store",
      headers: { Accept: "text/markdown, text/plain;q=0.9" }
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const markdown = await response.text();
    markdownCache.set(selectedLocale, markdown);
    return markdown;
  };

  const showLoading = (selectedLocale) => {
    content.replaceChildren();
    tableOfContents.replaceChildren();
    const loading = document.createElement("p");
    loading.className = "founder-note-loading";
    loading.textContent = text(selectedLocale, "loading");
    content.append(loading);
    content.setAttribute("aria-busy", "true");
  };

  const render = async (selectedLocale) => {
    const sequence = ++renderSequence;
    showLoading(selectedLocale);
    try {
      const markdown = await fetchMarkdown(selectedLocale);
      if (sequence !== renderSequence) return;
      const rendered = renderMarkdown(markdown, selectedLocale);
      content.replaceChildren(rendered.fragment);
      tableOfContents.replaceChildren(rendered.tocFragment);
      content.setAttribute("aria-busy", "false");
      renderedLocale = selectedLocale;
    } catch {
      if (sequence !== renderSequence) return;
      const error = document.createElement("p");
      error.className = "founder-note-error";
      error.textContent = text(selectedLocale, "error");
      content.replaceChildren(error);
      tableOfContents.replaceChildren();
      content.setAttribute("aria-busy", "false");
      renderedLocale = null;
    }
  };

  const synchronize = () => {
    const selectedLocale = locale();
    applyInterfaceCopy(selectedLocale);
    if (note.open && renderedLocale !== selectedLocale) {
      render(selectedLocale);
    }
  };

  note.addEventListener("toggle", synchronize);
  document.addEventListener("forgeplay:localechange", synchronize);
  synchronize();
})();
