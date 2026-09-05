const token = new URLSearchParams(location.search).get('t') || '';
const qt = token ? ('?t=' + encodeURIComponent(token)) : '';
const authHeaders = token ? { 'Authorization': 'Bearer ' + token } : {};

async function api(path,opts={}) {
 const res=await fetch(path,{...opts,headers:{'Content-Type':'application/json',...authHeaders,...opts.headers}});
 const body=(res.headers.get('content-type')||'').includes('json')?await res.json():await res.text();
 if(!res.ok)throw Error(body?.error||(res.status===401?'Access denied. Open the remote link from Kiln settings.':'Request failed ('+res.status+')'));
 return body;
}

// --- App state ---
const state = {
  sessions: [],
  activeId: null,
  activeSession: null,
  messages: [],
  live: { isBusy: false, streamingText: '', thinkingText: '', activeToolCalls: [], lastError: null },
  toolbar: { sessionMode: 'build', permissionMode: 'bypass', effortLevel: 'medium', thinkingEnabled: false, extendedContext: false, maxTurns: null },
  usage: { inputTokens: 0, outputTokens: 0, totalCost: 0 },
  settings: { defaultWorkDir: '~' },
  models: [],
  sidebarKind: 'code',
  rightTab: 'activity',
  attachments: [],  // { path, name }
  remote: null,
  search: '',
  showArchived: false,
  renamingId: null,
};

// --- Render ---
function escHTML(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' })[c]);
}

function matchesSearch(s, q) {
  if (!q) return true;
  const needle = q.toLowerCase();
  const tagQuery = needle.startsWith('#') ? needle.slice(1) : needle;
  return (
    s.name.toLowerCase().includes(needle) ||
    (s.workDir || '').toLowerCase().includes(needle) ||
    (s.group || '').toLowerCase().includes(needle) ||
    (s.tags || []).some(t => t.includes(tagQuery))
  );
}

function renderArchiveBar() {
  const bar = document.getElementById('archiveBar');
  const archivedCount = state.sessions.filter(s => s.kind === state.sidebarKind && s.isArchived).length;
  if (!archivedCount && !state.showArchived) { bar.innerHTML = ''; return; }
  const cls = state.showArchived ? 'on' : '';
  const label = state.showArchived ? '← Back to active' : `📦 Archive (${archivedCount})`;
  bar.innerHTML = `<button class="${cls}" id="archiveToggle">${label}</button>`;
  document.getElementById('archiveToggle').onclick = () => {
    state.showArchived = !state.showArchived;
    renderSessions();
    renderArchiveBar();
  };
}

function renderSessions() {
  const box = document.getElementById('sessionList');
  if(state.renamingId && box.contains(document.activeElement)) return;
  box.innerHTML = '';
  const filtered = state.sessions.filter(s =>
    s.kind === state.sidebarKind &&
    (state.showArchived ? s.isArchived : !s.isArchived) &&
    matchesSearch(s, state.search)
  );
  if (!filtered.length) {
    box.innerHTML = '<div class="empty">No ' + (state.showArchived ? 'archived' : state.sidebarKind) + ' sessions' + (state.search ? ' matching "' + escHTML(state.search) + '"' : '') + '.</div>';
    return;
  }
  // Pinned float to top, in a synthetic "Pinned" group. Everything else
  // keeps its real group. When searching, flatten so hits don't hide
  // behind collapsed groups.
  const groups = {};
  if (state.search) {
    groups['—'] = filtered.slice();
  } else {
    const pinned = filtered.filter(s => s.isPinned);
    if (pinned.length) groups['Pinned'] = pinned;
    for (const s of filtered) {
      if (s.isPinned) continue;
      const g = s.group || '—';
      (groups[g] = groups[g] || []).push(s);
    }
  }
  for (const [gname, list] of Object.entries(groups)) {
    const ge = document.createElement('div');
    ge.className = 'session-group';
    if (gname !== '—') {
      const lbl = document.createElement('div');
      lbl.className = 'session-group-label';
      lbl.textContent = gname;
      ge.appendChild(lbl);
    }
    for (const s of list) {
      const it = document.createElement('div');
      const cls = ['session-item'];
      if (s.id === state.activeId) cls.push('active');
      if (s.isArchived) cls.push('archived');
      it.className = cls.join(' ');
      it.dataset.id = s.id;

      const rowIcon = icon(s.forkedFrom ? 'git-branch' : s.kind === 'chat' ? 'message-square' : 'terminal');
      const pin = s.isPinned ? '<span class="si-pin" title="Pinned">📌</span>' : '';
      const tags = (s.tags || []).length
        ? `<div class="si-tags">${s.tags.map(t => `<span class="si-tag">#${escHTML(t)}</span>`).join('')}</div>`
        : '';

      // Inline rename mode
      if (state.renamingId === s.id) {
        it.innerHTML = `
          <span class="si-icon">${rowIcon}</span>
          <input class="si-rename" value="${escHTML(s.name)}" autofocus>
        `;
        const input = it.querySelector('.si-rename');
        const commit = async () => {
          const newName = input.value.trim();
          state.renamingId = null;
          if (newName && newName !== s.name) {
            await api('/api/session/rename', { method: 'POST', body: JSON.stringify({ sessionId: s.id, name: newName }) });
          }
          await refreshAll();
        };
        input.addEventListener('keydown', (e) => {
          if (e.key === 'Enter') { e.preventDefault(); commit(); }
          else if (e.key === 'Escape') { state.renamingId = null; renderSessions(); }
        });
        input.addEventListener('blur', commit);
        setTimeout(() => { input.focus(); input.select(); }, 0);
      } else {
        it.innerHTML = `
          <span class="si-icon">${rowIcon}</span>
          <div class="si-body">
            <div class="si-name">${pin}${escHTML(s.name)}</div>
            <div class="si-meta">${escHTML((s.workDir||"").split("/").filter(Boolean).pop()||"/")} · ${s.messageCount} msgs</div>
            ${tags}
          </div>
          <button class="si-delete" data-id="${s.id}" title="Delete">×</button>
        `;
        it.addEventListener('click', async (e) => {
          if (e.target.classList.contains('si-delete')) return;
          await api('/api/select', { method: 'POST', body: JSON.stringify({ sessionId: s.id }) });
          await refreshAll();
          if (window.innerWidth <= 900) document.querySelector('.layout').classList.remove('show-sidebar');
        });
        it.addEventListener('dblclick', (e) => {
          if (e.target.classList.contains('si-delete')) return;
          state.renamingId = s.id;
          renderSessions();
        });
        it.addEventListener('contextmenu', (e) => {
          e.preventDefault();
          openSessionMenu(e.clientX, e.clientY, s);
        });
        // Long-press for touch devices — same menu as right-click.
        let lpTimer = null;
        it.addEventListener('touchstart', (e) => {
          lpTimer = setTimeout(() => {
            const t = e.touches[0];
            openSessionMenu(t.clientX, t.clientY, s);
          }, 500);
        }, { passive: true });
        it.addEventListener('touchend', () => { if (lpTimer) clearTimeout(lpTimer); });
        it.addEventListener('touchmove', () => { if (lpTimer) clearTimeout(lpTimer); });
        it.querySelector('.si-delete').addEventListener('click', async (e) => {
          e.stopPropagation();
          if (!confirm('Delete session "' + s.name + '"?')) return;
          await api('/api/session/delete', { method: 'POST', body: JSON.stringify({ sessionId: s.id }) });
          await refreshAll();
        });
      }
      ge.appendChild(it);
    }
    box.appendChild(ge);
  }
}

function renderChatHeader() {
 const s=state.activeSession;
 document.getElementById('chatHdrName').textContent=s?.name||'Select a session';
 document.getElementById('chatWorkDir').textContent=s?.workDir||'';
 document.getElementById('chatWorkDir').title=s?.workDir||'';
 const model=state.models.find(m=>m.id===s?.model);
 const button=document.getElementById('chatHdrModel');
 button.hidden=!s; button.disabled=state.live.isBusy;
 button.innerHTML=s?brandIcon(model?.brand)+'<span>'+escHTML(model?.label||s.model)+'</span>'+icon('chevron-down'):'';
 document.getElementById('chatHdrBusy').hidden=!state.live.isBusy;
 document.getElementById('busyBadge').textContent=state.live.isBusy?'Working':'Connected';
 document.getElementById('activeSessionName').textContent=s?.name||'';
 document.getElementById('messageCount').textContent=state.messages.length+' messages';
 const total=(state.usage.inputTokens||0)+(state.usage.outputTokens||0);
 document.getElementById('contextInfo').textContent=total?formatTokens(total)+' tokens':'';
 document.getElementById('retryBtn').disabled=!s||state.live.isBusy||!state.messages.length;
 document.getElementById('exportBtn').disabled=!s;
 updateSendState(); hydrateIcons();
}

function renderMedia(media){
 let url;
 try{
  const candidate=new URL(media.source);
  if(['http:','https:'].includes(candidate.protocol)&&!candidate.username&&!candidate.password)url=candidate.href;
 }catch{}
 const local=!url;
 if(local){
  if(!state.activeId||!media.id)return '';
  url='/api/media?session='+encodeURIComponent(state.activeId)+'&id='+encodeURIComponent(media.id)+(token?'&t='+encodeURIComponent(token):'');
 }
 const id=escHTML(media.id),label=escHTML(media.label||media.kind),src=escHTML(url);
 const download=escHTML(local?url+'&download=1':url);
 let body='';
 if(media.kind==='image')body=`<img class="media-image" src="${src}" alt="${label}" loading="lazy" referrerpolicy="no-referrer">`;
 else if(media.kind==='video')body=`<video controls playsinline preload="none" aria-label="${label}" src="${src}"></video>`;
 else if(media.kind==='audio')body=`<audio controls preload="none" aria-label="${label}" src="${src}"></audio>`;
 else if(media.kind==='document')body=`<iframe class="media-document" src="${src}" title="${label}" loading="lazy" sandbox></iframe>`;
 return `<figure class="inline-media ${escHTML(media.kind)}" data-media="${id}">${body}<figcaption><span>${label}</span><span class="media-error" hidden>Preview unavailable</span><a href="${src}" target="_blank" rel="noopener noreferrer" title="Open media" aria-label="Open media">${icon('external-link')}</a><a href="${download}" ${local?'download':''} target="_blank" rel="noopener noreferrer" title="Download media" aria-label="Download media">${icon('download')}</a></figcaption></figure>`;
}

function hydrateMedia(root=document){
 root.querySelectorAll('.inline-media img,.inline-media video,.inline-media audio').forEach(el=>{
  if(el.dataset.mediaWired)return;el.dataset.mediaWired='true';
  el.addEventListener('error',()=>{el.closest('figure').querySelector('.media-error').hidden=false;if(el.tagName==='IMG')el.hidden=true;});
  if(el.tagName==='IMG')el.addEventListener('click',()=>{
   const modal=document.getElementById('modalContent');modal.replaceChildren();
   const title=document.createElement('h2');title.textContent=el.alt;
   const expanded=el.cloneNode(false);expanded.className='expanded-media-image';expanded.hidden=false;
   const row=document.createElement('div');row.className='row';
   const close=document.createElement('button');close.className='btn';close.textContent='Close';close.onclick=closeModal;
   row.appendChild(close);modal.append(title,expanded,row);showModal();
  });
 });
}

function renderBlock(block, key='') {
 if(block.type==='text') return '<div class="block-text">'+DOMPurify.sanitize(marked.parse(block.text||''),{USE_PROFILES:{html:true},FORBID_TAGS:['img','form','input','button','style','video','audio','iframe'],FORBID_ATTR:['style','id','name']})+'</div>'+(block.media||[]).map(renderMedia).join('');
 if(block.type==='thinking') return `<details data-disclosure="${escHTML(key)}"><summary>Reasoning</summary><div class="block-thinking">${escHTML(block.text||'')}</div></details>`;
 if(block.type==='trace') return `<details class="trace-block" data-disclosure="${escHTML(key)}"><summary>Run log · ${(block.entries||[]).length}</summary>${(block.entries||[]).map(e=>`<div class="trace-entry"><span class="lvl">${escHTML(e.level)}</span> ${escHTML(e.title)}\n${escHTML(e.detail)}</div>`).join('')}</details>`;
 if(block.type==='toolUse'){
  const t=block.tool;
  return `<details class="tool-block" data-disclosure="${escHTML(key)}"><summary class="tool-head"><span class="tdot ${t.isError?'error':t.isDone?'done':''}"></span><span>${escHTML(t.name)}</span></summary>${t.input?`<div class="tool-body">${escHTML(t.input)}</div>`:''}${t.result?`<div class="tool-result ${t.isError?'error':''}">${escHTML(t.result)}</div>`:''}</details>`;
 }
 if(block.type==='toolResult') return '';
 if(block.type==='attachment' && block.media?.length) return block.media.map(renderMedia).join('');
 if(block.type==='attachment') return `<div class="chip">${icon('paperclip')}<span class="chip-name" title="${escHTML(block.path)}">${escHTML(block.name)}</span></div>`;
 return '';
}

function renderMessages() {
 const box=document.getElementById('messages');
 const signature=JSON.stringify([state.activeId,state.messages,state.live]);
 if(signature===messageSignature) return;
 const selection=window.getSelection();
 if(selection&&!selection.isCollapsed&&box.contains(selection.anchorNode)) return;
 const atBottom=box.scrollHeight-box.scrollTop-box.clientHeight<80;
 const scrollTop=box.scrollTop;
 box.querySelectorAll('details').forEach(d=>{if(d.open)openDisclosures.add(d.dataset.disclosure);else openDisclosures.delete(d.dataset.disclosure);});
 const heading=(m)=>`<div class="msg-heading"><span class="msg-avatar">${m.role==='user'?icon('user'):brandIcon(state.models.find(x=>x.id===m.model)?.brand||'openai')}</span><span>${escHTML(m.role==='user'?(state.settings.userDisplayName||'You'):(m.assistantName||m.model||'Assistant'))}</span>${m.timestamp?`<time>${new Date(m.timestamp*1000).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}</time>`:''}${m.id?`<button class="icon-button copy-message" data-copy="${escHTML(m.id)}" title="Copy message" aria-label="Copy message">${icon('copy')}</button>`:''}</div>`;
 let html=state.messages.map(m=>`<article class="msg-wrap ${m.role==='user'?'user':'assistant'}" data-message="${escHTML(m.id)}">${heading(m)}<div class="msg">${(m.blocks||[]).map((b,i)=>renderBlock(b,m.id+':'+i)).join('')}</div></article>`).join('');
 const live=state.live;
 if(live.isBusy||live.streamingText||live.thinkingText||(live.activeToolCalls||[]).length){
  const blocks=[];
  if(live.thinkingText)blocks.push({type:'thinking',text:live.thinkingText});
  for(const t of live.activeToolCalls||[])blocks.push({type:'toolUse',tool:t});
  if(live.streamingText)blocks.push({type:'text',text:live.streamingText});
  const model=state.models.find(m=>m.id===state.activeSession?.model);
  html+=`<article class="msg-wrap assistant">${heading({role:'assistant',model:model?.id,assistantName:model?.label})}<div class="msg">${blocks.map((b,i)=>renderBlock(b,'live:'+i)).join('')||'<span class="live-dot"></span>'}</div></article>`;
 }
 if(live.lastError)html+='<div class="err-row">'+escHTML(live.lastError)+'</div>';
 if(!html)html='<div class="empty">'+escHTML(state.activeSession?.name||'Select a conversation')+'</div>';
 const template=document.createElement('template');template.innerHTML=html;
 const previous=new Map([...box.children].filter(n=>n.dataset.message).map(n=>[n.dataset.message,n]));
 const content=new Map(state.messages.map(m=>[m.id,state.activeId+JSON.stringify(m)]));
 const incoming=[...template.content.children];
 for(let i=0;i<incoming.length;i++){
  let node=incoming[i];const id=node.dataset.message,old=previous.get(id);
  if(old&&old._sourceSignature===content.get(id))node=old;
  else if(id)node._sourceSignature=content.get(id);
  if(box.children[i]!==node)box.insertBefore(node,box.children[i]||null);
 }
 while(box.children.length>incoming.length)box.lastElementChild.remove();
 messageSignature=signature;
 box.querySelectorAll('details').forEach(d=>d.open=openDisclosures.has(d.dataset.disclosure));
 box.querySelectorAll('.copy-message').forEach(b=>b.onclick=async()=>{const m=state.messages.find(m=>m.id===b.dataset.copy);try{await navigator.clipboard.writeText((m?.blocks||[]).filter(b=>b.type==='text').map(b=>b.text).join('\n\n'));flash('Copied');}catch{flash('Clipboard unavailable');}});
 hydrateIcons();hydrateMedia(box);
 if(followsOutput&&atBottom)box.scrollTop=box.scrollHeight;else box.scrollTop=scrollTop;
}

function renderToolbar(){
 const bar=document.getElementById('composerBar'),s=state.activeSession,tb=state.toolbar;
 if(!s){bar.innerHTML='';return;}
 if(bar.contains(document.activeElement))return;
 const model=state.models.find(m=>m.id===s.model);
 const select=(label,name,options,value,glyph)=>`<label class="control">${icon(glyph)}<select aria-label="${label}" data-control="${name}" ${state.live.isBusy?'disabled':''}>${options.map(([v,l])=>`<option value="${v}" ${v===value?'selected':''}>${l}</option>`).join('')}</select></label>`;
 let html='';
 if(s.kind!=='chat'){
 html+=select('Mode','sessionMode',[['build','Build'],['plan','Plan']],tb.sessionMode,'hammer');
 html+=select('Permissions','permissionMode',[['bypass','Bypass'],['ask','Guarded'],['deny','Read-only']],tb.permissionMode,'shield');
 }
 html+=select('Reasoning','reasoning',[['default','Reasoning'],...(model?.efforts||[]).map(e=>[e,e.charAt(0).toUpperCase()+e.slice(1)])],tb.thinkingEnabled?tb.effortLevel:'default','brain');
 if(model?.supportsFast)html+=`<button class="fast-toggle" id="fastToggle" aria-label="Fast mode" aria-pressed="${!!tb.openAIFastMode}" ${state.live.isBusy?'disabled':''}>${icon('zap')}${tb.openAIFastMode?'Fast':'Normal'}</button>`;
 bar.innerHTML=html;
 bar.querySelectorAll('select').forEach(el=>el.onchange=async()=>{
  const body={sessionId:s.id};
  if(el.dataset.control==='reasoning'){body.thinkingEnabled=el.value!=='default';if(body.thinkingEnabled)body.effortLevel=el.value;}
  else body[el.dataset.control]=el.value;
  try{state.toolbar=await api('/api/toolbar',{method:'POST',body:JSON.stringify(body)});}catch(e){flash(e.message);}
  el.blur();renderToolbar();
 });
 const fast=document.getElementById('fastToggle');
 if(fast)fast.onclick=async()=>{try{state.toolbar=await api('/api/toolbar',{method:'POST',body:JSON.stringify({sessionId:s.id,openAIFastMode:!tb.openAIFastMode})});renderToolbar();}catch(e){flash(e.message);}};
 hydrateIcons();
}

function formatTokens(n) {
  if (n >= 1_000_000) return (n/1_000_000).toFixed(1) + 'M';
  if (n >= 1_000) return Math.round(n/1_000) + 'K';
  return String(n);
}

function renderAttachments() {
  const box = document.getElementById('attachChips');
  if (!state.attachments.length) { box.innerHTML = ''; return; }
  box.innerHTML = state.attachments.map((a, i) => `
    <div class="chip">
      <span>${icon("paperclip")}</span>
      <span class="chip-name" title="${escHTML(a.path)}">${escHTML(a.name)}</span>
      <button class="chip-x" data-i="${i}">×</button>
    </div>
  `).join('');
  box.querySelectorAll('.chip-x').forEach(b => b.onclick = () => {
    state.attachments.splice(parseInt(b.dataset.i), 1);
    saveDraft();renderAttachments();updateSendState();
  });
}

function renderRightPanel() {
  const box = document.getElementById('rightBody');
  if (state.rightTab === 'activity') {
    const calls = state.live.activeToolCalls || [];
    if (!calls.length && !state.live.isBusy) { box.innerHTML = '<div class="empty">No activity yet.</div>'; return; }
    box.innerHTML = calls.map(t => `
      <div class="activity-item">
        <div class="ai-name">${escHTML(t.name)}</div>
        ${t.input ? `<div class="ai-input">${escHTML(t.input.slice(0, 500))}</div>` : ''}
      </div>
    `).join('') || '<div class="empty">Working…</div>';
  } else if (state.rightTab === 'stats') {
    box.innerHTML = `
      <div class="stats-row"><span class="sl">Input tokens</span><span class="sv">${formatTokens(state.usage.inputTokens || 0)}</span></div>
      <div class="stats-row"><span class="sl">Output tokens</span><span class="sv">${formatTokens(state.usage.outputTokens || 0)}</span></div>
      <div class="stats-row"><span class="sl">Total cost</span><span class="sv">$${(state.usage.totalCost || 0).toFixed(4)}</span></div>
      <div class="stats-row"><span class="sl">Sessions</span><span class="sv">${state.sessions.length}</span></div>
      <div class="stats-row"><span class="sl">Messages</span><span class="sv">${state.messages.length}</span></div>
    `;
  } else if (state.rightTab === 'remote') {
    const r = state.remote || {};
    const urls = r.urls || {};
    const ts = r.tailscale || {};
    const tsBadge = { active: '🟢 active', installed: '🟡 installed (not logged in)', absent: '⚫ not installed', error: '🔴 error' }[ts.status] || ts.status;
    box.innerHTML = `
      <div style="font-size:10px; color:var(--text-tertiary); font-weight:700; letter-spacing:1px; margin-bottom:8px;">URLS</div>
      ${urls.local ? `<div class="stats-row"><span class="sl">local</span><span class="sv" style="font-size:10px;">${urls.local}</span></div>` : ''}
      ${urls.lan ? `<div class="stats-row"><span class="sl">lan</span><span class="sv" style="font-size:10px;">${urls.lan}</span></div>` : ''}
      ${urls.tailscale ? `<div class="stats-row"><span class="sl">tailscale</span><span class="sv" style="font-size:10px;">${urls.tailscale}</span></div>` : ''}
      <div style="font-size:10px; color:var(--text-tertiary); font-weight:700; letter-spacing:1px; margin:16px 0 8px;">TAILSCALE</div>
      <div class="stats-row"><span class="sl">status</span><span class="sv" style="font-size:10px;">${tsBadge}</span></div>
      ${ts.ip ? `<div class="stats-row"><span class="sl">ip</span><span class="sv" style="font-size:10px;">${ts.ip}</span></div>` : ''}
      <div style="font-size:10px; color:var(--text-tertiary); font-weight:700; letter-spacing:1px; margin:16px 0 8px;">ACCESS</div>
      <div class="stats-row"><span class="sl">level</span><span class="sv" style="font-size:10px;">${r.accessLevel || '—'}</span></div>
      <div class="stats-row"><span class="sl">port</span><span class="sv">${r.port || '—'}</span></div>
    `;
  }
}

function render() {
  renderSessions();
  renderArchiveBar();
  renderChatHeader();
  renderMessages();
  renderToolbar();
  renderAttachments();
  renderRightPanel();
  hydrateIcons();
}

// --- Session context menu ---
function closeCtxMenu() {
  const m = document.getElementById('ctxMenu');
  m.classList.remove('show');
  m.innerHTML = '';
}
document.addEventListener('click', (e) => {
  const m = document.getElementById('ctxMenu');
  if (m.classList.contains('show') && !m.contains(e.target)) closeCtxMenu();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') closeCtxMenu();
});

function openSessionMenu(x, y, s) {
  const m = document.getElementById('ctxMenu');
  const pinLabel = s.isPinned ? 'Unpin' : 'Pin';
  const pinIcon = s.isPinned ? '📌' : '📍';
  const archLabel = s.isArchived ? 'Unarchive' : 'Archive';
  const archIcon = s.isArchived ? '📤' : '📦';
  const existingTags = (s.tags || []).map(t =>
    `<div class="ctx-item" data-act="untag" data-tag="${escHTML(t)}"><span class="ctx-icon">✕</span>Remove #${escHTML(t)}</div>`
  ).join('');
  m.innerHTML = `
    <div class="ctx-item" data-act="rename"><span class="ctx-icon">✎</span>Rename</div>
    <div class="ctx-item" data-act="pin"><span class="ctx-icon">${pinIcon}</span>${pinLabel}</div>
    <div class="ctx-item" data-act="duplicate"><span class="ctx-icon">⎘</span>Duplicate (empty)</div>
    <div class="ctx-sep"></div>
    <div class="ctx-item" data-act="group"><span class="ctx-icon">📁</span>Set group…</div>
    <div class="ctx-sub">
      <div class="ctx-item"><span class="ctx-icon">🏷</span>Tags</div>
      <div class="ctx-sub-menu">
        <div class="ctx-item" data-act="tag-add"><span class="ctx-icon">+</span>Add tag…</div>
        ${existingTags ? '<div class="ctx-sep"></div>' + existingTags : ''}
      </div>
    </div>
    <div class="ctx-sep"></div>
    <div class="ctx-item" data-act="copy-continuation"><span class="ctx-icon">📋</span>Copy as continuation</div>
    <div class="ctx-item" data-act="copy-path"><span class="ctx-icon">⌘</span>Copy path</div>
    <div class="ctx-item" data-act="copy-id"><span class="ctx-icon">#</span>Copy session ID</div>
    <div class="ctx-item" data-act="export"><span class="ctx-icon">⤓</span>Export markdown</div>
    <div class="ctx-item" data-act="export-json"><span class="ctx-icon">{ }</span>Export JSON</div>
    <div class="ctx-item" data-act="new-here"><span class="ctx-icon">+</span>New session here</div>
    <div class="ctx-sep"></div>
    <div class="ctx-item" data-act="clear"><span class="ctx-icon">🧹</span>Clear messages</div>
    <div class="ctx-item" data-act="archive"><span class="ctx-icon">${archIcon}</span>${archLabel}</div>
    <div class="ctx-sep"></div>
    <div class="ctx-item destructive" data-act="delete"><span class="ctx-icon">🗑</span>Delete</div>
  `;
  // Position (keep inside viewport)
  m.style.left = '0px'; m.style.top = '0px';
  m.classList.add('show');
  const rect = m.getBoundingClientRect();
  const px = Math.min(x, window.innerWidth - rect.width - 8);
  const py = Math.min(y, window.innerHeight - rect.height - 8);
  m.style.left = px + 'px';
  m.style.top = py + 'px';

  m.querySelectorAll('[data-act]').forEach(el => {
    el.addEventListener('click', async (ev) => {
      ev.stopPropagation();
      const act = el.dataset.act;
      closeCtxMenu();
      await handleSessionAction(act, s, el.dataset);
    });
  });
}

async function handleSessionAction(act, s, data) {
  const id = s.id;
  try {
    switch (act) {
      case 'rename':
        state.renamingId = id;
        renderSessions();
        return;
      case 'pin':
        await api('/api/session/pin', { method: 'POST', body: JSON.stringify({ sessionId: id }) });
        break;
      case 'duplicate':
        await api('/api/session/duplicate', { method: 'POST', body: JSON.stringify({ sessionId: id }) });
        break;
      case 'archive':
        await api('/api/session/archive', { method: 'POST', body: JSON.stringify({ sessionId: id }) });
        break;
      case 'clear':
        if (!confirm('Clear all messages in "' + s.name + '"? This cannot be undone.')) return;
        await api('/api/session/clear', { method: 'POST', body: JSON.stringify({ sessionId: id }) });
        break;
      case 'delete':
        if (!confirm('Delete session "' + s.name + '"?')) return;
        await api('/api/session/delete', { method: 'POST', body: JSON.stringify({ sessionId: id }) });
        break;
      case 'group': {
        const g = prompt('Group name (empty to remove from group):', s.group || '');
        if (g === null) return;
        await api('/api/session/group', { method: 'POST', body: JSON.stringify({ sessionId: id, group: g }) });
        break;
      }
      case 'tag-add': {
        const t = prompt('Add tag (no # prefix):', '');
        if (!t) return;
        await api('/api/session/tag', { method: 'POST', body: JSON.stringify({ sessionId: id, tag: t, op: 'add' }) });
        break;
      }
      case 'untag':
        await api('/api/session/tag', { method: 'POST', body: JSON.stringify({ sessionId: id, tag: data.tag, op: 'remove' }) });
        break;
      case 'copy-continuation': {
        const r = await api('/api/session/continuation?session=' + encodeURIComponent(id));
        await copyToClipboard(r.text || '');
        flash('Continuation prompt copied');
        return;
      }
      case 'copy-path':
        await copyToClipboard(s.workDir || '');
        flash('Path copied');
        return;
      case 'copy-id':
        await copyToClipboard(s.id);
        flash('Session ID copied');
        return;
      case 'export':
        window.location.href = '/api/export?session=' + encodeURIComponent(id) + (token ? '&t=' + encodeURIComponent(token) : '');
        return;
      case 'export-json':
        window.location.href = '/api/export-json?session=' + encodeURIComponent(id) + (token ? '&t=' + encodeURIComponent(token) : '');
        return;
      case 'new-here':
        await api('/api/session/new-here', { sessionId: id });
        flash('New session created');
        break;
    }
    await refreshAll();
  } catch (e) {
    alert('Action failed: ' + e.message);
  }
}

async function copyToClipboard(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    // Fallback for iOS Safari without clipboard permission.
    const ta = document.createElement('textarea');
    ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.select();
    try { document.execCommand('copy'); } catch {}
    document.body.removeChild(ta);
  }
}

let flashTimer = null;
function flash(msg) {
  let el = document.getElementById('flashToast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'flashToast';
    el.style.cssText = 'position:fixed; bottom:20px; left:50%; transform:translateX(-50%); background:var(--surface-elevated); color:var(--text); border:1px solid var(--border); border-radius:8px; padding:8px 16px; font-size:12px; z-index:200; box-shadow:0 4px 12px rgba(0,0,0,0.4); opacity:0; transition:opacity 0.2s;';
    document.body.appendChild(el);
  }
  el.textContent = msg;
  el.style.opacity = '1';
  if (flashTimer) clearTimeout(flashTimer);
  flashTimer = setTimeout(() => { el.style.opacity = '0'; }, 1800);
}

// --- Theme / accent sync with the native app ---
function applyServerAppearance(s) {
  if (!s) return;
  if (s.themeMode) {
    document.documentElement.setAttribute('data-theme', s.themeMode);
  }
  if (s.accentHex) {
    // Accent value arrives without "#" from the settings payload; accept
    // either form. The accent-muted variant derives with a fixed alpha.
    const hex = s.accentHex.startsWith('#') ? s.accentHex : '#' + s.accentHex;
    document.documentElement.style.setProperty('--accent', hex);
    document.documentElement.style.setProperty('--accent-muted', hex + '26'); // ~15%
  }
}

// --- Data loading ---
async function refreshAll() {
 if(refreshing)return;
 refreshing=true;
 try {
  const data=await api('/api/state');
  const previous=state.activeId;
  if(previous!==data.activeSessionId)saveDraft();
  state.sessions=data.sessions||[];
  state.activeId=data.activeSessionId;
  state.activeSession=state.sessions.find(s=>s.id===state.activeId)||null;
  state.messages=data.messages||[];
  state.live=data.live||state.live;
  state.toolbar=data.toolbar||state.toolbar;
  state.usage=data.usage||state.usage;
  state.settings={...state.settings,...data.settings};
  state.models=data.models||[];
  if(previous!==state.activeId){loadDraft();messageSignature='';openDisclosures.clear();followsOutput=true;}
  if(state.activeSession&&previous!==state.activeId){
   state.sidebarKind=state.activeSession.kind;
   document.querySelectorAll('.sidebar-tab').forEach(b=>{b.classList.toggle('active',b.dataset.kind===state.sidebarKind);b.setAttribute('aria-selected',b.dataset.kind===state.sidebarKind);});
  }
  applyServerAppearance(state.settings);
  document.getElementById('connectionState').textContent='Connected';
  render();
  if(previous!==state.activeId)document.getElementById('messages').scrollTop=document.getElementById('messages').scrollHeight;
 }catch(e){
  document.getElementById('connectionState').textContent='Disconnected';
  document.getElementById('busyBadge').textContent='Disconnected';
  showSendError(e.message);
 }finally{refreshing=false;}
}

// --- Composer ---
async function sendMessage() {
 const ta=document.getElementById('composerInput'),sid=state.activeId;
 const text=ta.value,attachments=state.attachments.slice();
 if((!text.trim()&&!attachments.length)||state.live.isBusy||sending||uploading||!sid||state.activeSession?.readOnly)return;
 sending=true;saveDraft();showSendError('');updateSendState();
 try{
  await api('/api/send',{method:'POST',body:JSON.stringify({text,sessionId:sid,attachments:attachments.map(a=>a.path)})});
  if(state.activeId===sid&&ta.value===text&&JSON.stringify(state.attachments)===JSON.stringify(attachments)){
   ta.value='';state.attachments=[];saveDraft();renderAttachments();
  }else if(state.activeId!==sid&&drafts[sid]?.text===text&&JSON.stringify(drafts[sid]?.attachments)===JSON.stringify(attachments)){delete drafts[sid];persistDrafts();}
  await refreshAll();
 }catch(e){showSendError(e.message);}
 finally{sending=false;updateSendState();}
}

async function handleFiles(files){
 const sid=state.activeId;
 if(!sid)return;
 uploading++;updateSendState();showSendError('');
 try{
 for(const file of files){
  if(file.size>4*1024*1024)throw Error('This remote connection accepts files up to 4 MB.');
  const base64=await new Promise((resolve,reject)=>{const r=new FileReader();r.onload=()=>resolve(r.result.split(',')[1]);r.onerror=()=>reject(Error('Could not read '+file.name));r.readAsDataURL(file);});
  const result=await api('/api/attach/upload',{method:'POST',body:JSON.stringify({name:file.name,base64})});
  if(!result.path)throw Error('Upload did not return an attachment.');
  const attachment={path:result.path,name:file.name};
  if(state.activeId===sid){state.attachments.push(attachment);saveDraft();renderAttachments();}
  else{const draft=drafts[sid]||{text:'',attachments:[]};draft.attachments.push(attachment);drafts[sid]=draft;persistDrafts();}
 }
 }catch(e){showSendError(e.message);}
 finally{uploading--;updateSendState();}
}

// --- Event wiring ---
document.getElementById('composerInput').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && (state.settings.sendKey !== 'cmdEnter' || e.metaKey || e.ctrlKey)) { e.preventDefault(); sendMessage(); }
});
document.getElementById('sendBtn').onclick = sendMessage;
document.getElementById('stopBtn').onclick = () => api('/api/interrupt', { method: 'POST' });
document.getElementById('attachBtn').onclick = () => document.getElementById('fileInput').click();
document.getElementById('fileInput').addEventListener('change', (e) => handleFiles(e.target.files));
document.getElementById('retryBtn').onclick = () => api('/api/retry', { method: 'POST' });
document.getElementById('exportBtn').onclick = () => {
  if (!state.activeId) return;
  window.location.href = '/api/export?session=' + encodeURIComponent(state.activeId) + (token ? '&t=' + encodeURIComponent(token) : '');
};

document.querySelectorAll('.sidebar-tab').forEach(b => b.onclick = () => {
  state.sidebarKind = b.dataset.kind;
  document.querySelectorAll('.sidebar-tab').forEach(x => x.classList.toggle('active', x === b));
  renderSessions();
  renderArchiveBar();
});
document.getElementById('sessionSearch').addEventListener('input', (e) => {
  state.search = e.target.value;
  renderSessions();
});
document.querySelectorAll('.right-tab').forEach(b => b.onclick = () => {
  state.rightTab = b.dataset.tab;
  document.querySelectorAll('.right-tab').forEach(x => x.classList.toggle('active', x === b));
  renderRightPanel();
});

// Drag-drop
const main = document.getElementById('main');
const overlay = document.getElementById('dropOverlay');
main.addEventListener('dragover', (e) => { e.preventDefault(); overlay.classList.add('show'); });
main.addEventListener('dragleave', (e) => { if (e.target === main) overlay.classList.remove('show'); });
main.addEventListener('drop', (e) => {
  e.preventDefault();
  overlay.classList.remove('show');
  if (e.dataTransfer.files.length) handleFiles(e.dataTransfer.files);
});
// Paste images
document.getElementById('composerInput').addEventListener('paste', (e) => {
  const items = e.clipboardData?.items || [];
  for (const it of items) {
    if (it.kind === 'file') {
      const f = it.getAsFile();
      if (f) handleFiles([f]);
    }
  }
});

// New Session modal
document.getElementById('newSessionBtn').onclick = () => {
  const m = document.getElementById('modalContent');
  const modelsOpts = state.models.map(x => `<option value="${escHTML(x.id)}">${escHTML(x.label)}</option>`).join('');
  m.innerHTML = `
    <h2>New Session</h2>
    <label>Kind</label>
    <select id="nsKind"><option value="code">Code</option><option value="chat">Chat</option></select>
    <label>Working Directory</label>
    <input id="nsWorkDir" value="${escHTML(state.settings.defaultWorkDir || '~')}">
    <label>Model</label>
    <select id="nsModel">${modelsOpts}</select>
    <div class="row">
      <button class="btn" onclick="closeModal()">Cancel</button>
      <button class="btn primary" id="nsCreate">Create</button>
    </div>
  `;
  document.getElementById('nsKind').value = state.sidebarKind;
  document.getElementById('nsCreate').onclick = async () => {
    await api('/api/session', { method: 'POST', body: JSON.stringify({
      kind: document.getElementById('nsKind').value,
      workDir: document.getElementById('nsWorkDir').value,
      model: document.getElementById('nsModel').value,
    })});
    closeModal();
    await refreshAll();
  };
  showModal();
};

function openModels(){
 const modal=document.getElementById('modalContent');
 modal.innerHTML='<h2>Models</h2><input id="modelSearch" type="search" placeholder="Search models" aria-label="Search models"><div class="model-list" id="modelList"></div><div class="row"><button class="btn" id="refreshModels">Refresh models</button><button class="btn" onclick="closeModal()">Close</button></div>';
 const renderList=()=>{
  const query=document.getElementById('modelSearch').value.toLowerCase();
  const box=document.getElementById('modelList');box.innerHTML='';
  for(const [group,label] of [['codex','Codex'],['older','Older models'],['opencode','OpenCode']]){
   const models=state.models.filter(m=>(group==='older'?m.older:m.provider===group&&!m.older)&&(m.id+' '+m.label).toLowerCase().includes(query));
   if(!models.length)continue;
   box.insertAdjacentHTML('beforeend','<div class="model-group">'+label+'</div>');
   for(const model of models){
    const b=document.createElement('button');b.className='model-option'+(model.id===state.activeSession?.model?' selected':'');
    b.innerHTML=brandIcon(model.brand)+'<span>'+escHTML(model.label)+'<small>'+escHTML(model.id)+'</small></span>';
    b.onclick=async()=>{try{await api('/api/model',{method:'POST',body:JSON.stringify({model:model.id,sessionId:state.activeId})});closeModal();await refreshAll();}catch(e){flash(e.message);}};
    box.appendChild(b);
   }
  }
  if(!box.children.length)box.innerHTML='<div class="empty">No matching models</div>';
  hydrateIcons();
 };
 document.getElementById('modelSearch').oninput=renderList;
 document.getElementById('refreshModels').onclick=async(e)=>{const b=e.currentTarget;b.disabled=true;try{await api('/api/models/refresh',{method:'POST'});await refreshAll();renderList();}catch(e){flash(e.message);}finally{b.disabled=false;}};
 renderList();showModal();document.getElementById('modelSearch').focus();
}

async function openSettings(){
 try{
  const settings=await api('/api/settings');state.remote=await api('/api/remote');
  const modal=document.getElementById('modalContent');
  modal.innerHTML='<h2>Settings</h2><nav class="settings-tabs"><button data-settings-tab="general" class="active">General</button><button data-settings-tab="chat">Chat & Composer</button><button data-settings-tab="remote">Remote Access</button></nav><div id="settingsBody"></div><div class="row"><button class="btn" onclick="closeModal()">Close</button></div>';
  const select=tab=>{
   modal.querySelectorAll('[data-settings-tab]').forEach(b=>b.classList.toggle('active',b.dataset.settingsTab===tab));
   const box=document.getElementById('settingsBody');
   if(tab==='general'){
    box.innerHTML=`<div class="setting-row"><span>Default model</span><span>${escHTML(settings.defaultModel)}</span></div><div class="setting-row"><span>Work directory</span><span>${escHTML(settings.defaultWorkDir)}</span></div><div class="setting-row"><span>Appearance</span><span>${escHTML(settings.themeMode)}</span></div><div class="setting-row"><span>Language</span><span>${escHTML(settings.language)}</span></div>`;
   }else if(tab==='chat'){
    box.innerHTML=`<div class="setting-row"><label for="autoCompact">Auto-compact at 90%</label><input type="checkbox" id="autoCompact" ${settings.autoCompactEnabled!==false?'checked':''}></div><div class="setting-row"><span>Send key</span><span>${settings.sendKey==='cmdEnter'?'Command + Enter':'Enter'}</span></div>`;
    document.getElementById('autoCompact').onchange=async(e)=>{const el=e.target,enabled=el.checked;el.disabled=true;try{const result=await api('/api/settings/chat',{method:'POST',body:JSON.stringify({autoCompactEnabled:enabled})});settings.autoCompactEnabled=result.autoCompactEnabled;el.checked=result.autoCompactEnabled;}catch(e){el.checked=!enabled;flash(e.message);}finally{el.disabled=false;}};
   }else{
    const remote=state.remote;
    box.innerHTML=`<div class="setting-row"><span>Access</span><span>${escHTML(remote.accessLevel)}</span></div><div class="setting-row"><span>Port</span><span>${escHTML(remote.port)}</span></div><div class="setting-row"><span>Tailscale</span><span>${escHTML(remote.tailscale?.status||'Unavailable')}</span></div><div class="row"><a class="btn" href="/api/settings/export${qt}" download>Export settings</a><button class="btn" onclick="pickFileAndUpload('/api/settings/import','Settings imported')">Import settings</button><button class="btn" onclick="pickFileAndUpload('/api/session/import','Session imported',true)">Import session</button></div>`;
   }
  };
  modal.querySelectorAll('[data-settings-tab]').forEach(b=>b.onclick=()=>select(b.dataset.settingsTab));
  select('general');showModal();
 }catch(e){flash(e.message);}
}
document.getElementById('settingsBtn').onclick = openSettings;

/// Prompt for a JSON file and POST its raw contents to `url`. If
/// `refreshAfter` is true, re-pulls state so the new session shows up.
window.pickFileAndUpload = function(url, okMsg, refreshAfter) {
  const inp = document.createElement('input');
  inp.type = 'file';
  inp.accept = 'application/json,.json';
  inp.onchange = async () => {
    const f = inp.files && inp.files[0];
    if (!f) return;
    try {
      const text = await f.text();
      const tq = token ? ('?t=' + encodeURIComponent(token)) : '';
      const res = await fetch(url + tq, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: text,
      });
      const j = await res.json().catch(() => ({}));
      if (!res.ok || j.error) throw new Error(j.error || ('HTTP ' + res.status));
      flash(okMsg || 'Imported');
      closeModal();
      if (refreshAfter) await refreshAll();
    } catch (e) {
      alert('Import failed: ' + e.message);
    }
  };
  inp.click();
};
function closeModal() { document.getElementById('modalBg').classList.remove('show'); modalOpener?.focus(); }
document.getElementById('modalBg').addEventListener('click', (e) => { if (e.target.id === 'modalBg') closeModal(); });
window.closeModal = closeModal;

function icon(name){return `<i data-lucide="${name}"></i>`;}

function brandIcon(brand){return brand==='terminal'?icon('terminal'):'<img class="model-logo" src="__OPENAI_LOGO__" alt="">';}

function hydrateIcons(){lucide.createIcons({attrs:{'aria-hidden':'true'}});}

function showSendError(message){const el=document.getElementById('sendError');el.textContent=message;el.hidden=!message;}

function updateSendState(){
 const ta=document.getElementById('composerInput'),busy=state.live.isBusy;
 document.getElementById('sendBtn').hidden=!!busy;
 document.getElementById('stopBtn').hidden=!busy;
 document.getElementById('sendBtn').disabled=!state.activeId||state.activeSession?.readOnly||busy||sending||uploading>0||(!ta.value.trim()&&!state.attachments.length);
 document.getElementById('attachBtn').disabled=!state.activeId||state.activeSession?.readOnly||sending;
 document.getElementById('clearDraft').disabled=sending||(!ta.value&&!state.attachments.length);
 ta.disabled=!state.activeId||state.activeSession?.readOnly;
 document.getElementById('draftState').textContent=uploading?'Uploading...':sending?'Sending...':ta.value.length?ta.value.length+' characters':'';
}

function persistDrafts(){
 try{localStorage.setItem('kiln.remote.drafts.v1',JSON.stringify(drafts));}
 catch{showSendError('Draft storage is unavailable. Keep this page open until you send.');}
}

function saveDraft(){
 if(!state.activeId)return;
 drafts[state.activeId]={text:document.getElementById('composerInput').value,attachments:state.attachments.slice()};
 persistDrafts();
}

function loadDraft(){
 const draft=drafts[state.activeId];
 document.getElementById('composerInput').value=typeof draft?.text==='string'?draft.text:'';
 state.attachments=Array.isArray(draft?.attachments)?draft.attachments.filter(a=>a&&typeof a.path==='string'&&typeof a.name==='string'):[];
 updateSendState();
}

function showModal(){
 modalOpener=document.activeElement;
 document.getElementById('modalBg').classList.add('show');
 hydrateIcons();
 requestAnimationFrame(()=>document.querySelector('#modalContent input,#modalContent button,#modalContent')?.focus());
}

function findInConversation(advance=false){
 const query=document.getElementById('findInput').value.toLowerCase().trim();
 const rows=[...document.querySelectorAll('[data-message]')];
 rows.forEach(r=>r.classList.remove('search-match'));
 const matches=query?rows.filter(r=>r.querySelector('.msg')?.textContent.toLowerCase().includes(query)):[];
 findIndex=advance&&matches.length?(findIndex+1)%matches.length:0;
 document.getElementById('findCount').textContent=matches.length?(findIndex+1)+' / '+matches.length:query?'No matches':'';
 if(matches.length){matches[findIndex].classList.add('search-match');matches[findIndex].scrollIntoView({block:'center'});followsOutput=false;}
}


let refreshing=false, sending=false, uploading=0, followsOutput=true, messageSignature='', modalOpener=null, findIndex=0;
const openDisclosures=new Set();
let drafts={};
try { drafts=JSON.parse(localStorage.getItem('kiln.remote.drafts.v1')||'{}'); if(!drafts||Array.isArray(drafts)||typeof drafts!=='object')drafts={}; } catch { drafts={}; }
document.getElementById('composerInput').addEventListener('input',()=>{saveDraft();updateSendState();});
document.getElementById('chatHdrModel').onclick=openModels;
document.getElementById('clearDraft').onclick=()=>{document.getElementById('composerInput').value='';state.attachments=[];saveDraft();renderAttachments();updateSendState();};
document.getElementById('expandComposer').onclick=e=>{const expanded=document.querySelector('.composer').classList.toggle('expanded');e.currentTarget.setAttribute('aria-pressed',expanded);};
document.getElementById('toggleTools').onclick=()=>{const layout=document.querySelector('.layout');if(innerWidth<=1100)layout.classList.toggle('show-right');else layout.classList.toggle('tools-hidden');};
document.getElementById('mobileSessions').onclick=()=>{document.querySelector('.layout').classList.toggle('show-sidebar');document.querySelector('.layout').classList.remove('show-right');};
document.getElementById('mobileTools').onclick=()=>{document.querySelector('.layout').classList.toggle('show-right');document.querySelector('.layout').classList.remove('show-sidebar');};
document.getElementById('panelScrim').onclick=()=>document.querySelector('.layout').classList.remove('show-sidebar','show-right');
document.getElementById('followBtn').onclick=()=>{followsOutput=!followsOutput;document.getElementById('followBtn').setAttribute('aria-pressed',followsOutput);if(followsOutput){const box=document.getElementById('messages');box.scrollTop=box.scrollHeight;}};
document.getElementById('messages').addEventListener('scroll',()=>{const box=document.getElementById('messages');followsOutput=box.scrollHeight-box.scrollTop-box.clientHeight<80;document.getElementById('followBtn').setAttribute('aria-pressed',followsOutput);},{passive:true});
document.getElementById('findBtn').onclick=()=>{document.getElementById('findBar').hidden=false;document.getElementById('findInput').focus();};
document.getElementById('findInput').oninput=()=>findInConversation();
document.getElementById('findNext').onclick=()=>findInConversation(true);
document.getElementById('findClose').onclick=()=>{document.getElementById('findBar').hidden=true;document.querySelectorAll('.search-match').forEach(r=>r.classList.remove('search-match'));};
document.addEventListener('keydown',e=>{
 if(e.key==='Escape'){closeModal();document.querySelector('.layout').classList.remove('show-sidebar','show-right');}
 if(e.key==='Tab'&&document.getElementById('modalBg').classList.contains('show')){
  const items=[...document.querySelectorAll('#modalContent button:not(:disabled),#modalContent input:not(:disabled),#modalContent select:not(:disabled),#modalContent a[href]')].filter(el=>el.getClientRects().length);
  const first=items[0],last=items.at(-1);
  if(e.shiftKey&&document.activeElement===first){e.preventDefault();last?.focus();}
  if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus();}
 }
});
window.addEventListener('beforeunload',saveDraft);
window.addEventListener('unhandledrejection',e=>{showSendError(e.reason?.message||'Request failed');e.preventDefault();});
hydrateIcons();

// Init
refreshAll();
setInterval(() => { if (!document.hidden) refreshAll(); }, 1800);
