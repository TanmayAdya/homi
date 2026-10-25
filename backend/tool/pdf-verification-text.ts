import { PDFArray, PDFDict, PDFDocument, PDFName, PDFRawStream, decodePDFRawStream } from 'pdf-lib';

export interface PaintedTextRun { text: string; fontSize: number; depth: number }
function check(value: unknown): asserts value { if (!value) throw new Error('PDF painted text validation failed.'); }
function withoutCommentsOrLiterals(content: string): string {
  const parts: string[] = []; let index = 0;
  while (index < content.length) {
    if (content[index] === '%') {
      while (index < content.length && !'\r\n'.includes(content[index])) index++;
      parts.push(' ');
    } else if (content[index] === '(') {
      index++; let depth = 1;
      while (index < content.length && depth > 0) {
        const character = content[index++];
        if (character === '\\') { if (index < content.length) index++; }
        else if (character === '(') depth++;
        else if (character === ')') depth--;
      }
      check(depth === 0); parts.push(' ');
    } else parts.push(content[index++]);
  }
  return parts.join('');
}

export function pageOperators(document: PDFDocument, index: number): string {
  const contents = document.getPage(index).node.Contents();
  return (contents instanceof PDFArray ? contents.asArray() : [contents]).filter(Boolean).map(ref => {
    const stream = document.context.lookup(ref); check(stream instanceof PDFRawStream);
    const decoded = decodePDFRawStream(stream).decode(); check(decoded.byteLength <= 16 * 1024 * 1024);
    return Buffer.from(decoded).toString('latin1');
  }).join('\n');
}

export function paintedTextRuns(document: PDFDocument, index: number): PaintedTextRun[] {
  const runs: PaintedTextRun[] = [], maps = new Map<PDFDict, Map<string, string>>();
  let decodedTotal = 0, objectCount = 0;
  const streamText = (stream: PDFRawStream): string => {
    const bytes = decodePDFRawStream(stream).decode(); decodedTotal += bytes.length;
    check(decodedTotal <= 32 * 1024 * 1024); return Buffer.from(bytes).toString('latin1');
  };
  const unicode = (hex: string): string => {
    check(hex.length > 0 && hex.length % 4 === 0 && hex.length <= 256);
    return new TextDecoder('utf-16be', { fatal: true }).decode(Buffer.from(hex, 'hex'));
  };
  const characterMap = (font: PDFDict): Map<string, string> => {
    const cached = maps.get(font); if (cached) return cached;
    const stream = document.context.lookup(font.get(PDFName.of('ToUnicode'))); check(stream instanceof PDFRawStream);
    const cmap = streamText(stream);
    const result = new Map<string, string>();
    const add = (source: string, destination: string) => {
      check(/^[\da-f]{4}$/i.test(source) && !result.has(source.toUpperCase()) && result.size < 65536);
      result.set(source.toUpperCase(), unicode(destination));
    };
    for (const block of cmap.matchAll(/beginbfchar([\s\S]*?)endbfchar/g)) {
      for (const entry of block[1].matchAll(/<([\dA-Fa-f]{4})>\s*<([\dA-Fa-f]+)>/g)) add(entry[1], entry[2]);
    }
    for (const block of cmap.matchAll(/beginbfrange([\s\S]*?)endbfrange/g)) {
      for (const entry of block[1].matchAll(/<([\dA-Fa-f]{4})>\s*<([\dA-Fa-f]{4})>\s*(?:<([\dA-Fa-f]+)>|\[([^\]]*)\])/g)) {
        const first = parseInt(entry[1], 16), last = parseInt(entry[2], 16); check(first <= last && last - first < 65536);
        const explicit = entry[4]?.match(/[\dA-Fa-f]+(?=>)/g);
        if (explicit) check(explicit.length === last - first + 1);
        for (let source = first; source <= last; source++) {
          const value = explicit ? explicit[source - first] : (BigInt(`0x${entry[3]}`) + BigInt(source - first)).toString(16).padStart(entry[3].length, '0');
          add(source.toString(16).padStart(4, '0'), value);
        }
      }
    }
    check(result.size > 0); maps.set(font, result); return result;
  };
  const decode = (content: string, resources: PDFDict, depth: number): void => {
    check(depth < 12 && ++objectCount <= 2000);
    let selected: PDFDict | undefined, fontSize = 0;
    const saved: { selected: PDFDict | undefined; fontSize: number }[] = [];
    const operators = withoutCommentsOrLiterals(content);
    for (const token of operators.matchAll(/\/([\w.-]+)\s+([\d.]+)\s+Tf|<([\dA-Fa-f]+)>\s*Tj|\/([\w.-]+)\s+Do|\b(q|Q)\b/g)) {
      if (token[1]) {
        selected = resources.lookupMaybe(PDFName.of('Font'), PDFDict)
          ?.lookupMaybe(PDFName.of(token[1]), PDFDict);
        fontSize = Number(token[2]); check(Number.isFinite(fontSize) && fontSize > 0);
      } else if (token[4]) {
        const objects = resources.lookup(PDFName.of('XObject'), PDFDict);
        const object = document.context.lookup(objects.get(PDFName.of(token[4]))); check(object instanceof PDFRawStream);
        if (object.dict.get(PDFName.of('Subtype')) === PDFName.of('Form')) {
          decode(streamText(object), object.dict.lookupMaybe(PDFName.of('Resources'), PDFDict) ?? resources, depth + 1);
        }
      } else if (token[5]) {
        if (token[5] === 'q') { check(saved.length < 100); saved.push({ selected, fontSize }); }
        else { const prior = saved.pop(); if (prior) ({ selected, fontSize } = prior); }
      } else {
        check(selected && token[3].length % 2 === 0 && runs.length < 50000);
        let text: string;
        if (selected.get(PDFName.of('Subtype')) === PDFName.of('Type0')) {
          const map = characterMap(selected); check(token[3].length % 4 === 0);
          text = token[3].match(/.{4}/g)!.map(raw => {
            const code = raw.toUpperCase(); check(code !== '0000' && map.has(code)); return map.get(code)!;
          }).join('');
        } else text = new TextDecoder('windows-1252').decode(Buffer.from(token[3], 'hex'));
        runs.push({ text, fontSize, depth });
      }
    }
  };
  const page = document.getPage(index), resources = page.node.Resources(); check(resources);
  const content = pageOperators(document, index); decodedTotal += Buffer.byteLength(content, 'latin1');
  decode(content, resources, 0); return runs;
}

export function paintedText(document: PDFDocument, index: number): string[] {
  return paintedTextRuns(document, index).map(run => run.text);
}
