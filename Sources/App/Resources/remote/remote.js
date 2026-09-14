const token = new URLSearchParams(location.search).get('t') || '';
const qt = token ? ('?t=' + encodeURIComponent(token)) : '';
const authHeaders = token ? { 'Authorization': 'Bearer ' + token } : {};

async function api(path,opts={}) {
 const url=new URL(path,location.href);
 if(url.origin!==location.origin||!url.pathname.startsWith('/api/'))throw Error('Invalid API destination');
 const res=await fetch(url,{...opts,redirect:'error',headers:{'Content-Type':'application/json',...authHeaders,...opts.headers}});
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
  live: { isBusy: false, streamingText: '', thinkingText: '', traceEntries: [], activeToolCalls: [], lastError: null },
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
 const context=state.context;
 const valid=context&&Number.isFinite(context.usedTokens)&&context.usedTokens>=0&&Number.isFinite(context.window)&&context.window>0;
 document.getElementById('contextInfo').textContent=valid?formatTokens(context.usedTokens)+' / '+formatTokens(context.window)+' · '+Math.floor(context.usedTokens/context.window*100)+'%':'Context unavailable';
 document.getElementById('contextInfo').title=valid?context.usedTokens.toLocaleString('en-US')+' / '+context.window.toLocaleString('en-US')+' tokens. Latest backend context, not total tokens processed':'Automatic compaction waits for reliable backend context';
 document.getElementById('retryBtn').disabled=!s||state.live.isBusy||!state.messages.length;
 document.getElementById('exportBtn').disabled=!s;
 updateSendState(); hydrateIcons();
}

function renderMedia(media){
 if(media.kind==='link')return renderRichLink(media);
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
 root.querySelectorAll('a[href]').forEach(a=>{const fixed=fixupXURL(a.href);if(fixed)a.href=fixed;});
 hydrateRichLinks(root);
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

function renderRichLink(media){
 const provider=escHTML(media.provider||media.label),label=escHTML(media.label||media.provider);
 let url;try{url=new URL(media.source);if(url.protocol!=='https:'||url.username||url.password)return '';}catch{return '';}
 return `<figure class="rich-link" data-link="${escHTML(media.id)}" data-session="${escHTML(state.activeId)}" data-provider="${provider}">
 <button class="link-load" aria-label="Load ${provider} embed"><img class="link-thumbnail" hidden alt="" referrerpolicy="no-referrer"><span class="link-play">${icon(media.provider==='Twitter / X'?'message-square':'circle-play')}</span></button>
 <div class="link-player" hidden></div><div class="link-post" hidden></div><figcaption><div class="link-caption"><span class="link-provider">${media.provider==='Twitter / X'?'X via fixupx.com':provider}</span><button class="icon-button link-retry" hidden title="Retry link preview" aria-label="Retry link preview">${icon('refresh-cw')}</button><button class="icon-button link-close" hidden title="Close embed" aria-label="Close embed">${icon('x')}</button><a class="icon-button" href="${escHTML(url.href)}" target="_blank" rel="noopener noreferrer" title="Open on ${media.provider==='Twitter / X'?'FixupX':provider}" aria-label="Open on ${media.provider==='Twitter / X'?'FixupX':provider}">${icon('external-link')}</a></div><strong class="link-title">${label}</strong><span class="link-author"></span><span class="link-status" role="status"></span></figcaption></figure>`;
}

function fixupXURL(raw){
 try{
  const url=new URL(raw);if(!['http:','https:'].includes(url.protocol)||url.username||url.password||url.port)return null;
  if(!['x.com','www.x.com','twitter.com','www.twitter.com','mobile.twitter.com','mobile.x.com','fixupx.com','www.fixupx.com','fxtwitter.com','www.fxtwitter.com'].includes(url.hostname))return null;
  const match=url.pathname.match(/^\/(?:[^/]+\/status|i\/web\/status)\/(\d{2,20})(?:\/|$)/);
  return match?'https://fixupx.com/i/status/'+match[1]:null;
 }catch{return null;}
}

function renderFixupXPost(card,post){
 const container=card.querySelector('.link-post');
 const media=items=>(items||[]).map(item=>renderMedia({id:item.url,source:item.url,kind:item.kind,label:item.kind==='image'?'Post image':'Post video'})).join('');
 const quote=post.quote?`<blockquote class="post-quote"><strong>${escHTML(post.quote.author)} @${escHTML(post.quote.handle)}</strong><div class="post-text">${escHTML(post.quote.text)}</div>${media(post.quote.media)}</blockquote>`:'';
 container.innerHTML=`<strong class="post-author">${escHTML(post.author)}</strong><span class="post-handle">@${escHTML(post.handle)}</span><div class="post-text">${escHTML(post.text)}</div>${media(post.media)}${quote}${post.timestamp?'<time>'+escHTML(new Date(post.timestamp*1000).toLocaleString())+'</time>':''}`;
 container.hidden=false;card.querySelector('.link-load').hidden=true;card.querySelector('.link-title').hidden=true;card.querySelector('.link-author').hidden=true;
 hydrateIcons();hydrateMedia(container);
}

const linkMetadataCache=new Map();
const linkPreviewObserver=new IntersectionObserver(entries=>{
 for(const entry of entries)if(entry.isIntersecting){linkPreviewObserver.unobserve(entry.target);loadLinkMetadata(entry.target);}
},{rootMargin:'200px'});

async function loadLinkMetadata(card,refresh=false){
 if(card._loading)return card._loading;
 const key=card.dataset.session+':'+card.dataset.link;
 card._loading=(async()=>{
  try{
   const theme=document.documentElement.dataset.theme==='light'?'light':'dark';
   let data=!refresh&&linkMetadataCache.get(key+theme);
   if(!data){
    data=await api('/api/link-preview?session='+encodeURIComponent(card.dataset.session)+'&id='+encodeURIComponent(card.dataset.link)+'&theme='+theme+(refresh?'&refresh=1':''));
    if(linkMetadataCache.size>=256)linkMetadataCache.clear();
    if(!data.unavailable)linkMetadataCache.set(key+theme,data);
   }
   card._metadata=data;
   card.querySelector('.link-title').textContent=data.title||card.dataset.provider;
   card.querySelector('.link-author').textContent=data.author||'';
   card.querySelector('.link-status').textContent=data.unavailable?'Metadata unavailable. The original link is still available.':'';
   card.querySelector('.link-retry').hidden=!data.unavailable;
   if(data.post)renderFixupXPost(card,data.post);
   if(data.thumbnail){
    const image=card.querySelector('.link-thumbnail');image.onload=()=>{image.hidden=false;};image.onerror=()=>{image.hidden=true;};image.src=data.thumbnail;
   }
   return data;
  }catch{
   card.querySelector('.link-status').textContent='Preview unavailable. Open the original link.';
   card.querySelector('.link-retry').hidden=false;
  }finally{card._loading=null;}
 })();
 return card._loading;
}

function hydrateRichLinks(root){
 // Removed cards must not remain retained by the observer between conversations.
 for(const card of observedLinkCards)if(!card.isConnected){linkPreviewObserver.unobserve(card);observedLinkCards.delete(card);}
 root.querySelectorAll('.rich-link').forEach(card=>{
  if(card.dataset.wired)return;card.dataset.wired='true';observedLinkCards.add(card);linkPreviewObserver.observe(card);
  const load=card.querySelector('.link-load'),player=card.querySelector('.link-player'),close=card.querySelector('.link-close');
  if(card.dataset.provider==='Twitter / X')load.hidden=true;
  close.onclick=()=>{player.replaceChildren();player.hidden=true;load.hidden=false;close.hidden=true;};
  card.querySelector('.link-retry').onclick=()=>loadLinkMetadata(card,true);
  load.onclick=async()=>{
   load.disabled=true;
   const data=card._metadata||await loadLinkMetadata(card);
   load.disabled=false;if(!data||!card.isConnected)return;
   const frame=document.createElement('iframe');frame.title=card.dataset.provider+' embed';frame.referrerPolicy='strict-origin-when-cross-origin';
   frame.allow='encrypted-media; fullscreen; picture-in-picture';frame.allowFullscreen=true;
   let url;try{url=new URL(data.embedURL);}catch{return;}
   if(url.protocol!=='https:'||url.username||url.password||!['www.youtube-nocookie.com','player.vimeo.com','open.spotify.com','w.soundcloud.com','www.tiktok.com'].includes(url.hostname))return;
   frame.setAttribute('sandbox','allow-scripts allow-same-origin allow-popups');frame.src=url.href;
   frame.style.height=Math.max(200,Math.min(440,Number(data.height)||300))+'px';
   player.replaceChildren(frame);player.hidden=false;load.hidden=true;close.hidden=false;
  };
 });
}
const observedLinkCards=new Set();

// Read-only counterpart of ToolPresentation.swift; isDone is an input boundary.
const toolPageSize=40, outputPageSize=8000, maximumPreviewSize=32000;
const timelineSessions=new Map();
let timelineRevision=0, renderedSession=null;
function timelineState(){
 if(!timelineSessions.has(state.activeId)){
  if(timelineSessions.size>=20)timelineSessions.delete(timelineSessions.keys().next().value);
  timelineSessions.set(state.activeId,{open:new Map(),limits:new Map(),pages:new Map()});
 }
 return timelineSessions.get(state.activeId);
}
function toolStatus(tool,live){
 if(tool.isError)return 'failure';
 if(tool.result!=null||Number.isFinite(tool.completedAt))return 'success';
 if(!live)return 'unconfirmed';
 return Number.isFinite(tool.startedAt)?'running':'pending';
}
const toolLabels={pending:'Pending',running:'Running',success:'Complete',failure:'Failed',unconfirmed:'Unconfirmed'};
const toolGlyphs={pending:'clock',running:'loader-circle',success:'circle-check',failure:'circle-x',unconfirmed:'circle-help'};
function toolSummary(tool){
 const input=String(tool.input||'');
 if(input.length>65536||new TextEncoder().encode(input).length>65536)return '';
 try{
  const object=JSON.parse(input);
  for(const key of ['command','cmd','file_path','path','pattern','query','url','description']){
   if(typeof object?.[key]==='string')return object[key].slice(0,180).replace(/\n/g,' ');
  }
 }catch{}
 return '';
}
function toolIcon(name){
 const value=String(name||'').toLowerCase();
 if(/bash|exec|terminal/.test(value))return 'terminal';
 if(/search|grep|glob/.test(value))return 'search';
 if(/write|edit|patch/.test(value))return 'pencil';
 if(/read/.test(value))return 'file-text';
 if(/web|fetch/.test(value))return 'globe';
 return 'wrench';
}
function timelineNode(tag,className='',text){
 const node=document.createElement(tag);node.className=className;
 if(text!=null)node.textContent=text;
 return node;
}
function timelineIcon(name){const node=document.createElement('i');node.dataset.lucide=name;return node;}
function pauseFollowing(){
 followsOutput=false;document.getElementById('followBtn').setAttribute('aria-pressed','false');
}
function updateTimeline(){pauseFollowing();timelineRevision++;messageSignature='';renderMessages();}
function timelineButton(label,glyph,action){
 const button=timelineNode('button','icon-button');button.type='button';
 button.title=label;button.setAttribute('aria-label',label);button.append(timelineIcon(glyph));button.onclick=action;
 return button;
}
function disclosure(key,label,className='',initiallyOpen=false){
 const details=timelineNode('details',className),summary=timelineNode('summary');
 details.dataset.nodeKey=key;details.dataset.disclosure=key;
 details.open=timelineState().open.get(key)??initiallyOpen;
 summary.setAttribute('aria-expanded',String(details.open));
 summary.title=(details.open?'Collapse ':'Expand ')+label.toLowerCase();
 summary.append(timelineIcon(details.open?'chevron-down':'chevron-right'),timelineNode('span','disclosure-label',label));
 summary.onclick=e=>{
  e.preventDefault();timelineState().open.set(key,!details.open);updateTimeline();
 };
 // Native details/summary handles Enter and Space without emulating button keys.
 details.append(summary);return details;
}
function textOutput(title,value,key){
 const text=String(value??''),limit=timelineState().limits.get(key)||outputPageSize;
 const box=timelineNode('section','tool-output');box.dataset.nodeKey=key;
 const header=timelineNode('div','output-heading');header.append(timelineNode('span','',title));
 header.append(timelineButton('Copy full '+title.toLowerCase(),'copy',async()=>{
  flash(await copyToClipboard(text)?'Copied':'Clipboard unavailable');
 }));
 const pre=timelineNode('pre','output-text',text?text.slice(0,limit):'Empty output');
 pre.tabIndex=0;pre.setAttribute('aria-label',title);box.append(header,pre);
 if(text.length>limit){
  const footer=timelineNode('div','output-footer','Preview truncated');
  if(limit<maximumPreviewSize){
   const more=timelineNode('button','output-more','Show more');more.type='button';
   more.onclick=()=>{timelineState().limits.set(key,Math.min(maximumPreviewSize,limit+outputPageSize));updateTimeline();};
   footer.append(more);
  }
  box.append(footer);
 }
 return box;
}
function toolCall(tool,live,legacyKey,scope=legacyKey){
 const key=JSON.stringify([scope,'call',tool.id]),status=toolStatus(tool,live);
 const row=disclosure(key,String(tool.name||'Tool'),'tool-call');
 if(legacyKey)row.dataset.disclosure=legacyKey;
 row.dataset.toolId=tool.id;row.dataset.status=status;
 const header=row.firstElementChild;
 header.setAttribute('aria-label',(tool.name||'Tool')+', '+toolLabels[status]);
 header.insertBefore(timelineIcon(toolIcon(tool.name)),header.children[1]);
 const label=header.querySelector('.disclosure-label'),summary=toolSummary(tool);
 label.classList.add('tool-label');
 if(summary)label.append(timelineNode('small','tool-summary',summary));
 if(Number.isFinite(tool.startedAt)&&Number.isFinite(tool.completedAt)&&tool.completedAt>=tool.startedAt){
  header.append(timelineNode('span','tool-duration',(tool.completedAt-tool.startedAt).toFixed(1)+'s'));
 }
 const badge=timelineNode('span','tool-state');badge.append(timelineIcon(toolGlyphs[status]),timelineNode('span','',toolLabels[status]));header.append(badge);
 if(row.open){
  const body=timelineNode('div','tool-details');body.dataset.nodeKey=key+':details';
  if(tool.input)body.append(textOutput('Input',tool.input,key+':input'));
  if(tool.result!=null){
   const output=disclosure(key+':result','Output','tool-result-disclosure');
   if(output.open)output.append(textOutput('Output',tool.result,key+':output'));
   body.append(output);
  }else body.append(timelineNode('p','tool-waiting',status==='unconfirmed'?'No completion result was recorded.':'Waiting for a result.'));
  row.append(body);
 }
 return row;
}
function appendTimelinePage(container,items,key,label,renderItem){
 const end=Math.min(timelineState().pages.get(key)??items.length,items.length),start=Math.max(0,end-toolPageSize);
 if(items.length>toolPageSize){
  const pager=timelineNode('div','tool-pager');
  const earlier=timelineButton('Earlier '+label.toLowerCase(),'chevron-up',()=>{timelineState().pages.set(key,start);updateTimeline();});earlier.disabled=start===0;
  const later=timelineButton('Later '+label.toLowerCase(),'chevron-down',()=>{
   const next=Math.min(items.length,end+toolPageSize);
   if(next===items.length)timelineState().pages.delete(key);else timelineState().pages.set(key,next);
   updateTimeline();
  });later.disabled=end===items.length;
  pager.append(earlier,timelineNode('span','',`${start+1}-${end} of ${items.length}`),later);container.append(pager);
 }
 const list=timelineNode('div','tool-list');list.dataset.nodeKey=key+':list';
 list.setAttribute('role','region');list.setAttribute('aria-label',label);list.tabIndex=0;
 items.slice(start,end).forEach((item,index)=>list.append(renderItem(item,start+index)));container.append(list);
}
function toolGroup(rawTools,live,legacyKey,scope){
 const tools=[...new Map(rawTools.map(tool=>[tool.id,tool])).values()];
 if(tools.length===1)return toolCall(tools[0],live,legacyKey,scope);
 const key=JSON.stringify([scope,'group',tools[0].id]),wrapper=timelineNode('div','tool-group');wrapper.dataset.nodeKey=key;
 const group=disclosure(key+':disclosure',tools.length+' tool calls','tool-group-disclosure');
 const active=tools.findLast(tool=>['pending','running'].includes(toolStatus(tool,live)));
 if(active)group.firstElementChild.append(timelineNode('span','group-active',active.name));
 const failures=tools.filter(tool=>tool.isError).length;
 if(failures)group.firstElementChild.append(timelineNode('span','group-failures',failures+' failed'));
 if(group.open)appendTimelinePage(group,tools,key,'Tool calls',tool=>toolCall(tool,live,undefined,scope));
 wrapper.append(group);
 if(!group.open&&active)wrapper.append(toolCall(active,live,undefined,scope));
 return wrapper;
}
function traceRow(entries,legacyKey,live=false){
 const key='trace:'+String(entries[0]?.id??legacyKey);
 const row=disclosure(key,'Run log','trace-block');row.dataset.disclosure=legacyKey;
 const header=row.firstElementChild;
 header.append(timelineNode('span','trace-count',String(entries.length)));
 for(const level of ['warning','error']){
  const count=entries.filter(entry=>entry.level===level).length;
  if(count)header.append(timelineNode('span','trace-'+level,count+' '+(level==='warning'?'warn':'err')));
 }
 if(live)header.append(timelineNode('span','trace-live','Live'));
 if(!row.open)return row;
 const actions=timelineNode('div','trace-actions');
 actions.append(timelineButton('Copy full run log','copy',async()=>{
  flash(await copyToClipboard(JSON.stringify(entries,null,2))?'Copied':'Clipboard unavailable');
 }));row.append(actions);
 appendTimelinePage(row,entries,key,'Log entries',(entry,index)=>{
  const entryKey=key+':entry:'+String(entry.id??index);
  const item=disclosure(entryKey,String(entry.title||'Event').slice(0,180),'trace-entry');
  item.dataset.traceId=String(entry.id??index);
  item.firstElementChild.append(timelineNode('span','trace-level',String(entry.level||'info').slice(0,24)));
  // Serialize only on expansion. Full-copy uses the untouched receipt, not its preview.
  if(item.open)item.append(textOutput('Receipt',JSON.stringify(entry,null,2),entryKey+':receipt'));
  return item;
 });
 return row;
}
function reasoningRow(text,key,live){
 const row=disclosure(key,'Reasoning','reasoning-disclosure',state.settings.thinkingCollapsedByDefault===false);
 row.firstElementChild.append(timelineNode('span','reasoning-state',live?'Working':'Complete'));
 if(row.open)row.append(textOutput('Reasoning',text,key+':text'));
 else row.append(timelineNode('span','reasoning-preview',String(text).slice(-240).trim().split('\n').at(-1)));
 return row;
}
function transcriptRows(blocks){
 const results=new Map(blocks.filter(b=>b.type==='toolResult').map(b=>[b.toolUseId,b]));
 const ids=new Set(blocks.filter(b=>b.type==='toolUse').map(b=>b.tool.id));
 const rows=[];let calls=[],first=0;
 const flush=()=>{if(calls.length){rows.push({index:first,tools:calls});calls=[];}};
 blocks.forEach((block,index)=>{
  if(block.type==='toolUse'){
   if(!calls.length)first=index;
   const result=results.get(block.tool.id);
   calls.push(result?{...block.tool,result:result.content,isError:result.isError}:block.tool);
  }else if(block.type==='toolResult'){
   if(!ids.has(block.toolUseId)){
    if(!calls.length)first=index;
    calls.push({id:block.toolUseId,name:'Tool result',input:'',result:block.content,isError:block.isError});
   }
  }else{flush();rows.push({index,block});}
 });flush();return rows;
}
function transcriptBody(blocks,messageKey,live,toolScope=messageKey){
 const body=timelineNode('div','msg');
 for(const row of transcriptRows(blocks)){
  const key=messageKey==='live'&&row.block?'live:'+row.block.type:messageKey+':'+row.index;
  let node;
  if(row.tools)node=toolGroup(row.tools,live,key,toolScope);
  else if(row.block.type==='thinking')node=reasoningRow(row.block.text||'',key,live&&!state.live.streamingText);
  else if(row.block.type==='trace')node=traceRow(row.block.entries||[],key,live);
  else{
   node=timelineNode('div');
   node.dataset.nodeKey=row.block.media?.length?'media-row:'+row.block.media[0].id:key;
   node.innerHTML=renderBlock(row.block,key);
   node.querySelectorAll('details').forEach(details=>{
    details.open=timelineState().open.get(key)||false;
    details.firstElementChild.onclick=e=>{e.preventDefault();timelineState().open.set(key,!details.open);updateTimeline();};
   });
  }
  node.classList.add('transcript-row');body.append(node);
 }
 return body;
}

// Reconcile within messages, not just whole articles. Stable media subtrees are opaque:
// changing prose or a tool receipt must not reload an iframe or reset a playing element.
function nodeKey(node){
 if(node.nodeType!==1)return '';
 for(const field of ['nodeKey','media','link'])if(node.dataset[field]!=null)return field+':'+node.dataset[field];
 return '';
}
function reconcileNode(old,fresh){
 if(old.nodeType!==fresh.nodeType||old.nodeName!==fresh.nodeName)return fresh;
 if(old.nodeType===3){if(old.data!==fresh.data)old.data=fresh.data;return old;}
 if(old.nodeType!==1)return old;
 if(fresh.matches('.inline-media,.rich-link')&&old._mediaSource===fresh._mediaSource)return old;
 for(const attribute of [...old.attributes])if(!fresh.hasAttribute(attribute.name))old.removeAttribute(attribute.name);
 for(const attribute of fresh.attributes)if(old.getAttribute(attribute.name)!==attribute.value)old.setAttribute(attribute.name,attribute.value);
 old.onclick=fresh.onclick;old._mediaSource=fresh._mediaSource;
 reconcileChildren(old,[...fresh.childNodes]);return old;
}
function reconcileChildren(parent,incoming){
 const previous=[...parent.childNodes],keyed=new Map(previous.filter(nodeKey).map(n=>[nodeKey(n),n])),used=new Set();
 incoming.forEach((fresh,index)=>{
  const key=nodeKey(fresh);
  const candidate=key?keyed.get(key):previous[index];
  const old=candidate&&!used.has(candidate)&&nodeKey(candidate)===key?candidate:null;
  const node=old?reconcileNode(old,fresh):fresh;
  if(old)used.add(old);
  if(parent.childNodes[index]!==node)parent.insertBefore(node,parent.childNodes[index]||null);
 });
 while(parent.childNodes.length>incoming.length)parent.lastChild.remove();
}

function renderBlock(block, key='') {
 if(block.type==='text') return '<div class="block-text">'+DOMPurify.sanitize(marked.parse(block.text||''),{USE_PROFILES:{html:true},FORBID_TAGS:['img','form','input','button','style','video','audio','iframe'],FORBID_ATTR:['style','id','name']})+'</div>'+(block.media||[]).map(renderMedia).join('');
 if(block.type==='thinking') return reasoningRow(block.text||'',key,false).outerHTML;
 if(block.type==='trace')return traceRow(block.entries||[],key).outerHTML;
 if(block.type==='toolUse')return toolCall(block.tool,false,key).outerHTML;
 if(block.type==='toolResult') return '';
 if(block.type==='attachment' && block.media?.length) return block.media.map(renderMedia).join('');
 if(block.type==='attachment') return `<div class="chip">${icon('paperclip')}<span class="chip-name" title="${escHTML(block.path)}">${escHTML(block.name)}</span></div>`;
 return '';
}

function renderMessages() {
 const box=document.getElementById('messages');
 const signature=JSON.stringify([state.activeId,state.messages,state.live,timelineRevision,state.settings.thinkingCollapsedByDefault]);
 if(signature===messageSignature) return;
 const changedSession=renderedSession!==state.activeId;
 const selection=window.getSelection();
 if(!changedSession&&selection&&!selection.isCollapsed&&box.contains(selection.anchorNode)) return;
 const atBottom=box.scrollHeight-box.scrollTop-box.clientHeight<80;
 const scrollTop=box.scrollTop;
 const top=box.getBoundingClientRect().top;
 const anchor=[...box.querySelectorAll('.transcript-row')].find(n=>n.getBoundingClientRect().bottom>top);
 const anchorOffset=anchor?.getBoundingClientRect().top;
 if(changedSession)box.replaceChildren();
 const heading=(m)=>`<div class="msg-heading"><span class="msg-avatar">${m.role==='user'?icon('user'):brandIcon(state.models.find(x=>x.id===m.model)?.brand||'openai')}</span><span>${escHTML(m.role==='user'?(state.settings.userDisplayName||'You'):(m.assistantName||m.model||'Assistant'))}</span>${m.timestamp?`<time>${new Date(m.timestamp*1000).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}</time>`:''}${m.id?`<button class="icon-button copy-message" data-copy="${escHTML(m.id)}" title="Copy message" aria-label="Copy message">${icon('copy')}</button>`:''}</div>`;
 const previous=new Map([...box.children].map(n=>[n.dataset.nodeKey,n]));
 const incoming=[];
 const appendMessage=(message,key,live=false,toolScope=key)=>{
  const source=JSON.stringify([message,live,toolScope,timelineRevision,state.settings.thinkingCollapsedByDefault]);
  const old=previous.get(key);
  if(old?._sourceSignature===source){incoming.push(old);return;}
  const article=timelineNode('article','msg-wrap '+(message.role==='user'?'user':'assistant'));
  article.dataset.nodeKey=key;
  if(message.id)article.dataset.message=message.id;
  article.innerHTML=heading(message);
  article.append(transcriptBody(message.blocks||[],key,live,toolScope));
  if(live&&!message.blocks.length)article.querySelector('.msg').append(timelineNode('span','run-lifecycle','Working'));
  article.querySelectorAll('.inline-media,.rich-link').forEach(node=>node._mediaSource=node.outerHTML);
  const node=old?reconcileNode(old,article):article;
  node._sourceSignature=source;incoming.push(node);
 };
 state.messages.forEach(message=>appendMessage(message,message.id));
 const live=state.live;
 if(live.isBusy||live.streamingText||live.thinkingText||(live.activeToolCalls||[]).length||(live.traceEntries||[]).length){
  const blocks=[];
  if(live.thinkingText)blocks.push({type:'thinking',text:live.thinkingText});
  if(live.traceEntries?.length)blocks.push({type:'trace',entries:live.traceEntries});
  for(const t of live.activeToolCalls||[])blocks.push({type:'toolUse',tool:t});
  if(live.streamingText)blocks.push({type:'text',text:live.streamingText});
  const model=state.models.find(m=>m.id===state.activeSession?.model);
  const user=state.messages.findLast(message=>message.role==='user');
  const toolScope=user?'assistant:'+user.id:'live:unanchored';
  appendMessage({role:'assistant',model:model?.id,assistantName:model?.label,blocks},'live',!!live.isBusy,toolScope);
 }
 if(live.lastError){const error=timelineNode('div','err-row',live.lastError);error.setAttribute('role','alert');incoming.push(error);}
 if(!incoming.length)incoming.push(timelineNode('div','empty',state.activeSession?.name||'Select a conversation'));
 for(let i=0;i<incoming.length;i++){
  const node=incoming[i];
  if(box.children[i]!==node)box.insertBefore(node,box.children[i]||null);
 }
 while(box.children.length>incoming.length)box.lastElementChild.remove();
 messageSignature=signature;renderedSession=state.activeId;
 box.querySelectorAll('.copy-message').forEach(b=>b.onclick=async()=>{const m=state.messages.find(m=>m.id===b.dataset.copy);try{await navigator.clipboard.writeText((m?.blocks||[]).filter(b=>b.type==='text').map(b=>b.text).join('\n\n'));flash('Copied');}catch{flash('Clipboard unavailable');}});
 hydrateIcons();hydrateMedia(box);
 if(changedSession||(followsOutput&&atBottom))box.scrollTop=box.scrollHeight;
 else if(anchor?.isConnected)box.scrollTop=scrollTop+anchor.getBoundingClientRect().top-anchorOffset;
 else box.scrollTop=scrollTop;
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
    return true;
  } catch {
    // HTTP LAN clients may not expose Clipboard API. Keep focus in the transcript.
    const focused=document.activeElement;
    const ta = document.createElement('textarea');
    ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.select();
    let copied=false;
    try { copied=document.execCommand('copy'); } catch {}
    document.body.removeChild(ta);
    focused?.focus({preventScroll:true});
    return copied;
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
  state.context=data.context||null;
  state.settings={...state.settings,...data.settings};
  state.models=data.models||[];
  if(previous!==state.activeId){loadDraft();messageSignature='';followsOutput=true;document.getElementById('followBtn').setAttribute('aria-pressed','true');}
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
let drafts={};
try { drafts=JSON.parse(localStorage.getItem('kiln.remote.drafts.v1')||'{}'); if(!drafts||Array.isArray(drafts)||typeof drafts!=='object')drafts={}; } catch { drafts={}; }
document.getElementById('composerInput').addEventListener('input',()=>{saveDraft();updateSendState();});
document.getElementById('chatHdrModel').onclick=openModels;
const composerOptions=timelineNode('div','composer-options');
const composerBar=document.getElementById('composerBar');
composerBar.before(composerOptions);
composerOptions.append(document.getElementById('chatHdrModel'),composerBar);
document.getElementById('clearDraft').onclick=()=>{document.getElementById('composerInput').value='';state.attachments=[];saveDraft();renderAttachments();updateSendState();};
document.getElementById('expandComposer').onclick=e=>{const expanded=document.querySelector('.composer').classList.toggle('expanded');e.currentTarget.setAttribute('aria-pressed',expanded);};
document.getElementById('toggleTools').onclick=()=>{const layout=document.querySelector('.layout');if(innerWidth<=1100)layout.classList.toggle('show-right');else layout.classList.toggle('tools-hidden');};
document.getElementById('mobileSessions').onclick=()=>{document.querySelector('.layout').classList.toggle('show-sidebar');document.querySelector('.layout').classList.remove('show-right');};
document.getElementById('mobileTools').onclick=()=>{document.querySelector('.layout').classList.toggle('show-right');document.querySelector('.layout').classList.remove('show-sidebar');};
document.getElementById('panelScrim').onclick=()=>document.querySelector('.layout').classList.remove('show-sidebar','show-right');
document.getElementById('followBtn').onclick=()=>{followsOutput=!followsOutput;document.getElementById('followBtn').setAttribute('aria-pressed',followsOutput);if(followsOutput){const box=document.getElementById('messages');box.scrollTop=box.scrollHeight;}};
document.getElementById('messages').addEventListener('scroll',()=>{const box=document.getElementById('messages');if(box.scrollHeight-box.scrollTop-box.clientHeight>=80)pauseFollowing();},{passive:true});
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
