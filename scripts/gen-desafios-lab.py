#!/usr/bin/env python3
"""Build a single-file Workshop Studio lab from the 9 Hugo challenge pages.
Extracts <main class=content> from each, normalizes headings, keeps code and
<details> (solutions stay collapsible), wraps as sections with sidebar nav.
"""
import re, html, sys

CHALLENGES = [
    ("desafio1", "01-kro-networking", "kro + ACK"),
    ("desafio2", "02-kro-pod-rds", "kro + ACK"),
    ("desafio3", "03-crossplane-vpc", "Crossplane"),
    ("desafio4", "04-argocd-iam-role", "ArgoCD EKS Capabilities"),
    ("desafio5", "05-argocd-applicationset", "ArgoCD EKS Capabilities"),
    ("desafio6", "06-argocd-sync-windows", "ArgoCD EKS Capabilities"),
    ("desafio7", "07-argocd-cross-account", "ArgoCD EKS Capabilities"),
    ("desafio8", "08-argocd-troubleshooting", "ArgoCD EKS Capabilities"),
    ("desafio9", "09-fleet-management", "Desafio Final"),
]
SRC = "/tmp/desafios"

def extract_main(h):
    m = re.search(r'<main[^>]*>(.*?)</main>', h, re.DOTALL)
    body = m.group(1) if m else h
    # remove any nested nav/breadcrumb/site-nav links back to index
    body = re.sub(r'<nav.*?</nav>', '', body, flags=re.DOTALL)
    # drop the first h1 (site "Desafios AWS") if present; keep challenge h1 as our section title (handled separately)
    return body

def title_of(h):
    t = re.search(r'<title>([^<]*)</title>', h).group(1)
    return t.replace(" - Desafios AWS", "").strip()

sections, sidebar = [], []
groups_seen = set()
for sid, fname, group in CHALLENGES:
    raw = open(f"{SRC}/{fname}.html").read()
    title = title_of(raw)
    body = extract_main(raw)
    # remove the challenge's own top h1 (we render our own section h1)
    body = re.sub(r'<h1[^>]*>.*?</h1>', '', body, count=1, flags=re.DOTALL)
    # downgrade h2->h2, keep as is; the lab css styles h2/h3
    sections.append((sid, title, group, body))
    sidebar.append((sid, title, group))

# build grouped sidebar
side_html = []
last_group = None
for sid, title, group in sidebar:
    if group != last_group:
        side_html.append(f'<div class="sidebar-section">{html.escape(group)}</div>')
        last_group = group
    short = re.sub(r'^Desafio \d+:\s*', '', title)
    side_html.append(f'<a href="#{sid}">{html.escape(short)}</a>')

sections_html = []
for sid, title, group, body in sections:
    sections_html.append(f'<section id="{sid}"><h1>{html.escape(title)}</h1>\n{body}</section>')

CSS = open(sys.argv[1]).read()
out = sys.argv[2]
tpl = f'''<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Platform Engineering Challenges</title>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/monokai-sublime.min.css">
<style>
{CSS}
/* solutions and hugo details render as our collapsible callouts */
details{{background:var(--info-bg);border-left:4px solid var(--info-border);border-radius:4px;margin:1rem 0;padding:0}}
details summary{{padding:10px 18px;cursor:pointer;font-weight:600;color:var(--text-secondary)}}
details > *:not(summary){{margin-left:18px;margin-right:18px}}
</style>
</head>
<body>
<div class="topbar"><div class="topbar-title"><span>&#9656;</span> Platform Engineering Challenges</div></div>
<nav class="sidebar">
<div class="sidebar-section">Visão Geral</div>
<a href="#intro">Introdução</a>
{chr(10).join(side_html)}
</nav>
<main class="content">
<section id="intro"><h1>Platform Engineering Challenges</h1>
<p>9 desafios hands-on para aprender a criar abstrações de infraestrutura com <strong>kro</strong>, <strong>ACK</strong>, <strong>Crossplane</strong> e <strong>ArgoCD EKS Capabilities</strong>. Cada desafio tem uma solução oculta - tente resolver sozinho primeiro.</p>
<table>
<tr><th>Grupo</th><th>Desafios</th></tr>
<tr><td>kro + ACK</td><td>1. Networking Stack | 2. Pod + RDS</td></tr>
<tr><td>Crossplane</td><td>3. VPC Composition</td></tr>
<tr><td>ArgoCD EKS Capabilities</td><td>4. IAM Role | 5. ApplicationSet | 6. Sync Windows | 7. Cross-account | 8. Troubleshooting</td></tr>
<tr><td>Desafio Final</td><td>9. Fleet Management (hub-spoke)</td></tr>
</table>
</section>
{chr(10).join(sections_html)}
</main>
<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
<script>
hljs.highlightAll();
document.querySelectorAll('pre').forEach(function(pre){{
  if(pre.querySelector('code')){{
    var btn=document.createElement('button');btn.className='copy-btn';btn.textContent='Copy';
    btn.onclick=function(){{navigator.clipboard.writeText(pre.querySelector('code').textContent);btn.textContent='Copied!';setTimeout(function(){{btn.textContent='Copy'}},1500);}};
    pre.style.position='relative';pre.appendChild(btn);
  }}
}});
var secs=document.querySelectorAll('section[id]');var links=document.querySelectorAll('.sidebar a');
window.addEventListener('scroll',function(){{var top=window.scrollY+80;secs.forEach(function(s){{if(s.offsetTop<=top&&s.offsetTop+s.offsetHeight>top){{links.forEach(function(l){{l.classList.remove('active')}});var a=document.querySelector('.sidebar a[href="#'+s.id+'"]');if(a)a.classList.add('active');}}}});}});
</script>
</body>
</html>'''
open(out, "w").write(tpl)
print(f"gerado: {out} ({len(sections)} desafios)")
