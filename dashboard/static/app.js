'use strict';
const $ = (selector) => document.querySelector(selector);
const token = $('meta[name="td-token"]').content;
const esc = (value) => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const displayName = (value) => String(value || 'Terminal').replace(/_agent$/i, '').replace(/[_-]/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
const providerName = (value) => ({codex:'Codex',claude:'Claude',claudex:'Claudex',hermes:'Hermes',grok:'Grok',shell:'Shell'}[value] || value);
const stateName = (s) => s.stale ? 'Last seen' : ({running: s.report_by==='system' ? 'Prompt delivered' : s.report_at ? 'Working' : 'Running · unreported',waiting:'Ready for input',blocked:'Needs you',done:'Reported done',shell:'Shell open'}[s.status] || 'Unknown');
const age = (seconds) => !seconds ? 'not yet' : seconds < 60 ? 'just now' : seconds < 3600 ? `${Math.floor(seconds / 60)}m ago` : seconds < 86400 ? `${Math.floor(seconds / 3600)}h ago` : `${Math.floor(seconds / 86400)}d ago`;
const ago = (timestamp) => age(Math.max(1, Date.now()/1000 - timestamp));
let state = null, currentView = 'overview', currentFilter = 'all', navSelection = '', toastTimer, fetching = false, offline = false;
let detailId = null, outputText = null, renderKey = '', navigatorOptionsKey = '';

async function api(path, body) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 45000);
  try {
    const response = await fetch(path, {method:body === undefined ? 'GET':'POST',headers:{'X-TD-Token':token,'Content-Type':'application/json'},body:body === undefined ? undefined : JSON.stringify(body),signal:controller.signal});
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || 'The request could not be completed.');
    return data;
  } catch (error) {
    if (error.name === 'AbortError') throw new Error('This is taking longer than expected. Refresh before retrying an action.');
    throw error;
  } finally { clearTimeout(timer); }
}
function toast(message, error=false) {
  clearTimeout(toastTimer);
  $('#toast').textContent=message;
  $('#toast').classList.toggle('error',error);
  $('#toast').hidden=false;
  toastTimer=setTimeout(() => $('#toast').hidden=true,error ? 11000:5500);
}
async function act(path, body, button) {
  const text = button?.textContent;
  if (button) { button.disabled=true; if (button.id !== 'navigation-toggle') button.textContent='One moment…'; }
  try {
    const result=await api(path,body);
    if (result.message) toast(result.message);
    await loadState(true);
    return result;
  } catch(error) { toast(error.message,true); return null; }
  finally { if (button?.isConnected) { button.disabled=false; if (button.id !== 'navigation-toggle') button.textContent=text; } }
}
async function loadState(force=false) {
  if (fetching) return;
  fetching=true;
  try {
    state=await api('/api/state'); offline=false;
    render(force);
  } catch(error) {
    offline=true;
    $('#error-banner').textContent='Connection paused. Your last overview is held here. Reopen or refresh the dashboard to reconnect.';
    $('#error-banner').hidden=false;
    $('#connection').innerHTML='<span class="status-dot error"></span> Connection paused';
    if (state) render(true);
    else { $('#loading').innerHTML='<h2>Your workspace is taking a moment.</h2><p>Use Refresh to reconnect. Your terminals continue independently.</p>'; }
  } finally { fetching=false; }
}
function changeView(view) {
  if (!['overview','sessions','activity'].includes(view)) return;
  currentView=view;
  history.replaceState(null,'',view === 'overview' ? location.pathname : `#${view}`);
  render(true);
}
function render(force=false) {
  if (!state) return;
  $('#loading').hidden=Boolean(state.updated_at) || state.sessions.length>0;
  $('#nav-count').textContent=state.counts.total;
  $('#demo-badge').hidden=!state.demo; $('#demo-note').hidden=!state.demo;
  const pending=state.proposals.filter(p => p.status==='pending');
  $('#activity-dot').hidden=pending.length===0;
  const stale=state.stale || offline;
  if (!offline) {
    $('#connection').innerHTML=`<span class="status-dot ${stale?'error':''}"></span> ${state.demo?'Edward demo':stale?'Waiting for a fresh scan':'Connected to your Mac'}`;
    const warning=state.error || state.warnings.join(' ');
    $('#error-banner').hidden=!warning && !stale;
    $('#error-banner').textContent=warning || (stale ? 'Gathering a fresh view. Terminal controls resume when discovery catches up.' : '');
  }
  const date=new Intl.DateTimeFormat('en',{weekday:'long',month:'long',day:'numeric'}).format(new Date());
  $('#date-label').textContent=date.toUpperCase();
  $('#freshness').textContent=state.updated_at ? `${state.demo?'Demo':'Local'} · Updated ${ago(state.updated_at)}${stale?' · waiting for a fresh scan':''}`:'Waiting for first scan';
  $('#awake-select').value=state.awake.state || 'off';
  const labels={overview:['Overview','A little room to think.','Your terminals keep moving. Find your next small step here.'],sessions:['All terminals','Everything has a place.','Find the right session. Pick up where you left off.'],activity:['Activity','The loops are held.','What changed, what was sent, and what needs your review.']};
  $('#view-label').textContent=labels[currentView][0]; $('#page-title').textContent=labels[currentView][1]; $('#page-subtitle').textContent=labels[currentView][2];
  document.querySelectorAll('.nav-item').forEach(b => { b.classList.toggle('active',b.dataset.view===currentView); b.setAttribute('aria-current',b.dataset.view===currentView?'page':'false'); });
  ['overview','sessions','activity'].forEach(view => $(`#${view}-view`).hidden=view!==currentView || !$('#loading').hidden);
  const stableSessions=state.sessions.map(({observed_at,...session})=>session);
  const key=JSON.stringify([stableSessions,state.controller,state.events,state.proposals,currentView,currentFilter,offline]);
  if (!force && key===renderKey) return;
  renderKey=key;
  renderFocus(pending);
  $('#overview-count').textContent=state.counts.total;
  $('#overview-sessions').innerHTML=state.sessions.length ? state.sessions.slice(0,5).map(sessionRow).join('')+(state.sessions.length>5?`<button class="overflow-note" data-view="sessions">${state.sessions.length-5} more ${state.sessions.length===6?"terminal":"terminals"}, all held here <span>↗</span></button>`:'') : empty('A fresh workspace.','Open a terminal and it will appear here automatically.');
  renderSessions(); renderNavigator(); renderEvents(); renderProposals();
  const active=state.counts.agents, attention=state.counts.attention;
  $('#workspace-brief').textContent=attention ? `${attention} ${attention===1?'update is':'updates are'} held here. Just take the next one.` : active ? `${active} agent ${active===1?'process is':'processes are'} running. Updates will land here.` : 'Everything has a place. You don’t have to hold it all.';
  $('#brief-stats').innerHTML=`<span><strong>${state.counts.total}</strong> open</span><span><strong>${active}</strong> agents</span><span><strong>${attention}</strong> need you</span>`;
}
function empty(title,text) { return `<div class="empty-state"><h3>${esc(title)}</h3><p>${esc(text)}</p></div>`; }
function sessionRow(s) {
  const cls=s.project.toLowerCase().includes('edward')?'edward':s.provider;
  const summary=s.report_at ? `<span class="session-summary">${esc(s.summary)}</span>`:'';
  return `<div class="session-row ${s.pinned?'pinned':''}"><button class="session-main" data-detail="${esc(s.id)}" aria-label="View ${esc(displayName(s.project))}, ${esc(s.tty)}"><span class="avatar ${esc(cls)}">${esc(displayName(s.project)[0])}</span><span class="session-copy"><span class="session-name">${esc(displayName(s.project))}${s.pinned?'<span class="pin-indicator"> · FOCUS</span>':''}</span><span class="session-meta"><span>${esc(providerName(s.provider))}</span><span class="divider">·</span><span>${esc(s.tty.replace('/dev/',''))}</span>${s.report_at?`<span class="divider">·</span><span>${ago(s.report_at)}</span>`:''}</span>${summary}</span></button><span class="session-status ${s.stale?'stale':esc(s.status)}">${esc(stateName(s))}</span><button class="row-arrow" data-detail="${esc(s.id)}" aria-label="Details for ${esc(s.tty)}">↗</button></div>`;
}
function renderFocus(pending) {
  const card=$('#focus-card');
  card.classList.remove('calm');
  if (pending.length && !state.sessions.some(s=>s.pinned)) {
    const proposal=pending[0], target=state.sessions.find(s=>s.id===proposal.session);
    card.innerHTML=`<div class="focus-eyebrow"><span><span class="status-dot"></span> JUST THE NEXT THING</span><span class="focus-tag">FOR YOUR REVIEW</span></div><h2 id="focus-title">A next step, already thought through.</h2><p>${esc(displayName(proposal.actor))} has a proposed task${target?` for ${esc(displayName(target.project))}`:''}. ${esc(proposal.reason)}</p><div class="focus-actions"><button class="button primary" data-view="activity">Review the handoff <span>→</span></button><span class="small muted">${pending.length>1?`${pending.length-1} more held in Activity`:'You have the final say.'}</span></div>`;
    return;
  }
  const s=state.sessions.find(s=>s.id===state.next_session);
  if (s) {
    const headline=s.pinned?`${displayName(s.project)} is your focus.`:s.status==='done'?`${displayName(s.project)} has a result.`:`${displayName(s.project)} ${s.status==='blocked'?'needs one decision.':'is ready for you.'}`;
    card.innerHTML=`<div class="focus-eyebrow"><span><span class="status-dot"></span> ${s.pinned?'YOUR FOCUS, HELD':'JUST THE NEXT THING'}</span><span class="focus-tag">${esc(s.pinned?'PINNED':stateName(s).toUpperCase())}</span></div><h2 id="focus-title">${esc(headline)}</h2><p>${esc(s.summary)}</p><div class="focus-actions"><button class="button primary" data-detail="${esc(s.id)}">Pick it up <span>→</span></button><button class="text-button" data-note="snooze" data-session="${esc(s.id)}">Park for 30m</button>${s.needs_attention?`<button class="text-button" data-note="acknowledge" data-session="${esc(s.id)}">Seen ✓</button>`:''}</div>`;
  } else {
    card.classList.add('calm');
    const title=state.counts.total?'Your terminals are here.':'Make yourself a little space.';
    const text=state.counts.total?'No new reported decisions. Choose a focus, or let your navigator gather the next update.':'Open a terminal to begin. This is where the activity, decisions, and small wins will land.';
    card.innerHTML=`<div class="focus-eyebrow"><span><span class="status-dot"></span> A MOMENT OF CLARITY</span><span class="focus-tag">ALL HELD</span></div><h2 id="focus-title">${title}</h2><p>${text}</p><div class="focus-actions"><button class="button primary" data-view="sessions">${state.counts.total?'Choose a focus':'Explore terminals'} <span>→</span></button></div><div class="all-clear-art" aria-hidden="true"></div>`;
  }
}
function renderSessions() {
  const query=$('#session-search').value.toLowerCase().trim();
  const rows=state.sessions.filter(s => (!query || [s.project,s.cwd,s.provider,s.name,s.tty,s.summary].join(' ').toLowerCase().includes(query)) && (currentFilter==='all' || currentFilter==='attention' && s.needs_attention || currentFilter==='agents' && s.provider!=='shell'));
  $('#all-sessions').innerHTML=rows.length?rows.map(sessionRow).join(''):empty(query?'No matching terminals.':currentFilter==='attention'?'Nothing needs you right now.':'No terminals yet.',query?'Try a project name, agent name, or TTY.':'New sessions and updates appear here automatically.');
  document.querySelectorAll('.filter').forEach(b=>{b.classList.toggle('active',b.dataset.filter===currentFilter);b.setAttribute('aria-pressed',String(b.dataset.filter===currentFilter));});
}
function renderNavigator() {
  const control=state.controller, agents=state.sessions.filter(s=>s.provider!=='shell' && !s.stale);
  if (!navSelection && control.session) navSelection=control.session;
  const key=JSON.stringify(agents.map(s=>[s.id,s.project,s.provider,s.tty]));
  if (key!==navigatorOptionsKey) {
    navigatorOptionsKey=key;
    $('#navigator-select').innerHTML='<option value="">Choose an agent session</option>'+agents.map(s=>`<option value="${esc(s.id)}">${esc(displayName(s.project))} · ${esc(providerName(s.provider))} · ${esc(s.tty.replace('/dev/',''))}</option>`).join('');
  }
  $('#navigator-select').value=navSelection;
  const selected=agents.find(s=>s.id===navSelection);
  const enabled=Boolean(control.enabled);
  $('#navigator-select').disabled=enabled;
  const name=control.enabled?displayName(control.name):selected?displayName(selected.project):'Your co-pilot';
  $('#navigator-title').textContent=name;
  $('#navigator-avatar').textContent=name==='Your co-pilot'?'↗':name[0];
  const status={off:'You’re holding the map',ready:'Ready · awaiting check-in',active:'Connected · '+(control.last_seen?ago(control.last_seen):'just now'),quiet:'Quiet · last check-in '+(control.last_seen?ago(control.last_seen):'not yet'),disconnected:'Session disconnected'};
  $('#navigator-state').textContent=status[control.state] || status.off;
  $('#navigation-toggle').setAttribute('aria-checked',String(enabled));
  $('#navigation-toggle').disabled=!enabled && (!selected || state.stale || offline);
  $('#handoff-button').disabled=!enabled || !control.connected || offline;
  $('#navigator-explainer').textContent=enabled?(control.state==='disconnected'?'This agent is no longer connected. Pause navigation, then select its new session.':control.state==='ready'?'Access is ready. Give your agent the handoff below; its first check-in will appear here.':control.state==='quiet'?'No recent check-in. Open the agent terminal to see whether it needs you.':'Your agent can read and focus sessions. Pause any time to take back the map.'):'Choose an agent. Give it the handoff. Stay in control.';
}
function eventItem(e) {
  return `<div class="event-item"><span class="event-dot"></span><div class="event-copy"><p>${esc(e.message)}</p><small>${esc(e.actor==='you'?'You':displayName(e.actor))} · ${ago(e.time)}</small></div></div>`;
}
function renderEvents() {
  $('#recent-events').innerHTML=state.events.length?state.events.slice(0,3).map(eventItem).join(''):'<p class="small muted">A quiet start. New updates will land here.</p>';
  $('#all-events').innerHTML=state.events.length?state.events.map(eventItem).join(''):empty('The story starts here.','Focus a terminal or connect a navigator. Each action leaves a small receipt.');
}
function renderProposals() {
  const pending=state.proposals.filter(p=>['pending','uncertain','sending'].includes(p.status));
  $('#proposals-section').innerHTML=pending.length?`<div class="section-heading"><h2>For your review <span class="count-badge">${pending.length}</span></h2></div>`+pending.map(p=>{
    const target=state.sessions.find(s=>s.id===p.session), ready=target?.ready_to_send && target.instance===p.instance && !offline;
    return `<article class="proposal-card"><span class="eyebrow">${p.status==='pending'?'PROPOSED BY '+esc(displayName(p.actor)):esc(p.status.toUpperCase())}</span><h3>${target?esc(displayName(target.project)):'Disconnected terminal'} <span class="small muted">${target?esc(target.tty):esc(p.session)}</span></h3><p>${esc(p.reason)}</p><pre>${esc(p.prompt)}</pre><div class="proposal-actions">${p.status==='pending'?`<button class="button primary" data-proposal="approve" data-id="${esc(p.id)}" ${ready?'':'disabled'}>Approve & send →</button><button class="button" data-proposal="dismiss" data-id="${esc(p.id)}">Dismiss</button>`:''}<button class="text-button" data-copy-proposal="${esc(p.id)}">Copy prompt</button>${target?`<button class="text-button" data-detail="${esc(target.id)}">Inspect terminal ↗</button>`:''}<span class="small">${p.status==='uncertain'?'Delivery could not be confirmed. Inspect the terminal; this will not be retried automatically.':p.status==='sending'?'Delivery is in progress. Do not resend the prompt.':ready?'Sends the exact text above to this waiting agent.':'Delivery waits for a fresh report confirming this agent is ready for input.'}</span></div></article>`;
  }).join(''):'';
}
function showDetail(id) {
  const s=state.sessions.find(s=>s.id===id);
  if (!s) return toast('That terminal is no longer connected.',true);
  detailId=id; outputText=null;
  const disabled=s.stale || state.stale || offline;
  $('#detail-content').innerHTML=`<h2 id="detail-title">${esc(displayName(s.project))}</h2><div class="detail-meta"><span class="session-status ${esc(s.status)}">${esc(stateName(s))}</span><span>${esc(providerName(s.provider))}</span><span>${esc(s.app)} · ${esc(s.tty)}</span></div><div class="detail-path">${esc(s.cwd || 'Working directory unavailable')}<br>Session: ${esc(s.id)}</div><div class="detail-report"><p>${esc(s.summary)}</p><span class="small">${s.report_at?`Reported by ${esc(displayName(s.report_by))} · ${ago(s.report_at)} · expires after 10 minutes`:'Observed process state. No fresh agent report yet.'}</span>${s.evidence?`<p class="small">Evidence: ${esc(s.evidence)}</p>`:''}</div><div class="dialog-actions"><button class="button primary" data-focus="${esc(s.id)}" ${disabled || !s.can_focus?'disabled':''}>Open terminal ↗</button><button class="button" data-note="pin" data-session="${esc(s.id)}">${s.pinned?'Release focus':'Make this my focus'}</button>${s.needs_attention?`<button class="text-button" data-note="acknowledge" data-session="${esc(s.id)}">Seen ✓</button>`:''}</div><div class="terminal-toolbar"><span class="small muted">Recent visible output · read on request</span><button class="text-button" id="inspect-button" ${disabled || !s.can_read?'disabled':''}>Inspect output ↓</button></div><pre id="terminal-output" class="terminal-output" hidden></pre><div id="output-warning" class="output-warning" hidden>Local terminal text · untrusted content · common credentials masked on a best-effort basis</div>${!s.can_read?'<p class="small muted">This terminal is observation only. Open it in its own app.</p>':''}`;
  if (!$('#detail-dialog').open) $('#detail-dialog').showModal();
}
async function copy(text, button, label='Copied. Ready to hand over.') {
  try { await navigator.clipboard.writeText(text); toast(label); }
  catch { toast('Clipboard access is unavailable. Select and copy the displayed text.',true); }
}

// Delegated controls keep keyboard focus stable while live data refreshes.
document.addEventListener('click', async event=>{
  const button=event.target.closest('button');
  if (!button || button.disabled) return;
  if (button.dataset.view) return changeView(button.dataset.view);
  if (button.dataset.filter) { currentFilter=button.dataset.filter; return renderSessions(); }
  if (button.dataset.detail) return showDetail(button.dataset.detail);
  if (button.classList.contains('close-dialog')) return button.closest('dialog').close();
  if (button.dataset.note) {
    const result=await act('/api/note',{session:button.dataset.session,action:button.dataset.note},button);
    if (result && $('#detail-dialog').open) $('#detail-dialog').close();
    return;
  }
  if (button.dataset.focus) return act('/api/session',{session:button.dataset.focus,action:'focus'},button);
  if (button.dataset.proposal) return act('/api/proposal',{id:button.dataset.id,action:button.dataset.proposal},button);
  if (button.dataset.copyProposal) {
    const proposal=state.proposals.find(p=>p.id===button.dataset.copyProposal);
    return copy(proposal.prompt,button,'Prompt copied. Choose the destination carefully.');
  }
  if (button.id==='inspect-button') {
    const result=await act('/api/session',{session:detailId,action:'read'},button);
    if (result && $('#detail-dialog').open && detailId===result.session) {
      outputText=result.text; $('#terminal-output').textContent=outputText || '(No visible output)';
      $('#terminal-output').hidden=false; $('#output-warning').hidden=false; button.textContent='Refresh output ↻';
    }
  }
});
$('#refresh-button').addEventListener('click',async function(){await act('/api/refresh',{},this);});
$('#session-search').addEventListener('input',renderSessions);
$('#navigator-select').addEventListener('change',function(){navSelection=this.value;renderNavigator();});
$('#navigation-toggle').addEventListener('click',async function(){
  const result=await act('/api/controller',{session:navSelection,enabled:!state.controller.enabled},this);
  if (result) renderNavigator();
});
$('#handoff-button').addEventListener('click',async function(){
  this.disabled=true;
  try { const guide=await api('/api/guide'); $('#handoff-text').value=guide.text; $('#handoff-dialog').showModal(); }
  catch(error){toast(error.message,true);} finally {renderNavigator();}
});
$('#copy-handoff').addEventListener('click',function(){copy($('#handoff-text').value,this);});
$('#help-button').addEventListener('click',()=>$('#help-dialog').showModal());
$('#awake-select').addEventListener('change',async function(){const value=this.value;this.disabled=true;await act('/api/awake',{duration:value});this.disabled=false;this.value=state.awake.state;});
$('#demo-walkthrough').addEventListener('click',async function(){
  const result=await act('/api/demo',{},this);
  if (result) {navSelection='demo:1';changeView('activity');}
});
document.querySelectorAll('dialog').forEach(dialog=>dialog.addEventListener('click',event=>{if(event.target===dialog){const box=dialog.getBoundingClientRect();if(event.clientX<box.left||event.clientX>box.right||event.clientY<box.top||event.clientY>box.bottom)dialog.close();}}));
document.addEventListener('keydown',event=>{
  if (/INPUT|TEXTAREA|SELECT/.test(event.target.tagName) || document.querySelector('dialog[open]') || event.metaKey || event.ctrlKey || event.altKey) return;
  if (event.key==='/') {event.preventDefault();changeView('sessions');$('#session-search').focus();}
  if (['1','2','3'].includes(event.key)) {event.preventDefault();changeView(['overview','sessions','activity'][Number(event.key)-1]);}
});
window.addEventListener('hashchange',()=>changeView(location.hash.slice(1) || 'overview'));
const hash=location.hash.slice(1);if(['sessions','activity'].includes(hash))currentView=hash;
loadState();setInterval(()=>{if(!document.hidden)loadState();},3000);
document.addEventListener('visibilitychange',()=>{if(!document.hidden)loadState(true);});
