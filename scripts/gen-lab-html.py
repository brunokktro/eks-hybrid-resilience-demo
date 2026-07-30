#!/usr/bin/env python3
"""Generate the single-file Workshop Studio lab HTML from the runbook markdown.
Callouts (blockquotes) become COLLAPSIBLE <details> to save screen space.
Usage: gen-lab-html.py <runbook.md> <out.html> "<Title>" "<Customer>"
"""
import sys, re, html

md_path, out_path, title, customer = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
raw = open(md_path).read()
# drop frontmatter
raw = re.sub(r'^---\n.*?\n---\n', '', raw, flags=re.DOTALL)

lines = raw.split('\n')
sections = []          # (sid, title, duration, html_body)
sidebar = []           # (sid, label)
cur = {"sid": "intro", "title": "Introdução", "dur": "", "body": []}
i = 0

def esc(t): return html.escape(t)

def inline(t):
    t = esc(t)
    t = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', t)
    t = re.sub(r'`(.+?)`', r'<code>\1</code>', t)
    t = re.sub(r'!\[(.*?)\]\((.+?)\)', r'<img src="\2" alt="\1"/>', t)
    t = re.sub(r'\[(.+?)\]\((.+?)\)', r'<a href="\2">\1</a>', t)
    return t

def flush(c):
    if c["title"]:
        sections.append((c["sid"], c["title"], c["dur"], "\n".join(c["body"])))

sid_count = 0
while i < len(lines):
    ln = lines[i]
    m2 = re.match(r'^## (.+)', ln)
    if m2:
        flush(cur)
        heading = m2.group(1).strip()
        dur = ""
        dm = re.search(r'\((\d+\s*min)\)', heading)
        if dm: dur = dm.group(1)
        clean = re.sub(r'\s*\(\d+\s*min\)', '', heading)
        # sid
        fm = re.match(r"Fase\s+([0-9a-z-]+)", clean, re.I)
        if fm: sid = "fase" + fm.group(1).lower().replace("-","")
        else:
            sid_count += 1; sid = "sec" + str(sid_count)
        sidebar.append((sid, clean))
        cur = {"sid": sid, "title": clean, "dur": dur, "body": []}
        i += 1; continue
    # everything else accumulates into current body as raw md lines
    cur["body"].append(ln)
    i += 1
flush(cur)

def render_body(mdbody):
    out = []
    blk = mdbody.split('\n')
    j = 0
    while j < len(blk):
        line = blk[j]
        # code fence
        cf = re.match(r'^```(\w*)', line)
        if cf:
            lang = cf.group(1) or ""
            code = []
            j += 1
            while j < len(blk) and not blk[j].startswith('```'):
                code.append(blk[j]); j += 1
            j += 1
            cls = f' class="language-{lang}"' if lang else ''
            out.append(f'<pre><code{cls}>{esc(chr(10).join(code))}</code></pre>')
            continue
        # blockquote -> collapsible details
        if line.startswith('>'):
            q = []
            while j < len(blk) and blk[j].startswith('>'):
                q.append(re.sub(r'^>\s?', '', blk[j])); j += 1
            text = " ".join(x for x in q if x.strip())
            # choose callout type + summary label from leading keyword
            low = text.lower()
            if low.startswith(('dica', 'tip')): ctype, label = 'success', 'Dica'
            elif low.startswith(('nota', 'resultado esperado', 'nuance', 'comportamento', 'requisito')): ctype, label = 'warn', 'Nota'
            elif low.startswith(('pré-requisito','pre-requisito','ferramentas')): ctype, label = 'info', 'Setup'
            else: ctype, label = 'info', 'Detalhe'
            # summary = first 60 chars
            summ = re.sub(r'^(dica|tip|nota|detalhe)[:\s-]*', '', text, flags=re.I)
            summ_short = (summ[:70] + '...') if len(summ) > 73 else summ
            out.append(f'<details class="callout callout-{ctype}"><summary>{label}: {inline(summ_short)}</summary><div>{inline(text)}</div></details>')
            continue
        # table
        if line.startswith('|') and j+1 < len(blk) and re.match(r'^\|[-:\s|]+\|', blk[j+1]):
            header = [c.strip() for c in line.strip('|').split('|')]
            j += 2
            rows = []
            while j < len(blk) and blk[j].startswith('|'):
                rows.append([c.strip() for c in blk[j].strip('|').split('|')]); j += 1
            th = ''.join(f'<th>{inline(h)}</th>' for h in header)
            trs = ''.join('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>' for r in rows)
            out.append(f'<table><tr>{th}</tr>{trs}</table>')
            continue
        # h3
        h3 = re.match(r'^### (.+)', line)
        if h3:
            out.append(f'<h3>{inline(h3.group(1))}</h3>'); j += 1; continue
        # list
        if re.match(r'^[-*] ', line):
            items = []
            while j < len(blk) and re.match(r'^[-*] ', blk[j]):
                items.append(f'<li>{inline(re.sub(r"^[-*] ", "", blk[j]))}</li>'); j += 1
            out.append('<ul>' + ''.join(items) + '</ul>')
            continue
        # blank
        if not line.strip():
            j += 1; continue
        # paragraph
        para = [line]; j += 1
        while j < len(blk) and blk[j].strip() and not re.match(r'^(```|>|\||#|[-*] )', blk[j]):
            para.append(blk[j]); j += 1
        out.append(f'<p>{inline(" ".join(para))}</p>')
    return "\n".join(out)

# build sidebar html (group heuristically)
side_html = ['<div class="sidebar-section">Visão Geral</div>']
for sid, label in sidebar:
    side_html.append(f'<a href="#{sid}">{esc(label)}</a>')

sections_html = []
for sid, stitle, dur, body in sections:
    dbadge = f' <span class="duration">{dur}</span>' if dur else ''
    sections_html.append(f'<section id="{sid}"><h1>{esc(stitle)}{dbadge}</h1>\n{render_body(body)}</section>')

CSS = open(sys.argv[5]).read() if len(sys.argv) > 5 else ""

tpl = f'''<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>{esc(title)}</title>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/monokai-sublime.min.css">
<style>
{CSS}
</style>
</head>
<body>
<div class="topbar"><div class="topbar-title"><span>&#9656;</span> {esc(title)} ({esc(customer)})</div></div>
<nav class="sidebar">
{chr(10).join(side_html)}
</nav>
<main class="content">
{chr(10).join(sections_html)}
</main>
<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
<script>
hljs.highlightAll();
document.querySelectorAll('pre').forEach(function(pre){{
  var btn=document.createElement('button');btn.className='copy-btn';btn.textContent='Copy';
  btn.onclick=function(){{navigator.clipboard.writeText(pre.querySelector('code').textContent);btn.textContent='Copied!';setTimeout(function(){{btn.textContent='Copy'}},1500);}};
  pre.appendChild(btn);
}});
var sections=document.querySelectorAll('section[id]');
var links=document.querySelectorAll('.sidebar a');
window.addEventListener('scroll',function(){{
  var top=window.scrollY+80;
  sections.forEach(function(s){{
    if(s.offsetTop<=top&&s.offsetTop+s.offsetHeight>top){{
      links.forEach(function(l){{l.classList.remove('active')}});
      var a=document.querySelector('.sidebar a[href="#'+s.id+'"]');if(a)a.classList.add('active');
    }}
  }});
}});
</script>
</body>
</html>'''
open(out_path, 'w').write(tpl)
print(f"gerado: {out_path} ({len(sections)} secoes)")
