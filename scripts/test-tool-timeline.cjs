// Synthetic, network-isolated browser contract. Never launches Kiln or reads chat stores.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..');
const assets = path.join(root, 'Sources/App/Resources/remote');
const read = name => fs.readFileSync(path.join(assets, name), 'utf8');
const png = fs.readFileSync(path.join(root, 'Sources/App/Resources/brands/OpenAI-white-monoblossom.png'));
const html = read('index.html').replace('/*STYLES*/', () => read('remote.css'))
  .replace('/*APPLICATION*/', () => read('remote.js'))
  .replace('<!--VENDOR-->', () => ['purify.min.js', 'marked.umd.js', 'lucide.min.js'].map(f => '<script>' + read('vendor/' + f) + '</script>').join('\n'))
  .replaceAll('__OPENAI_LOGO__', 'data:image/png;base64,' + png.toString('base64'));
const output = fs.mkdtempSync(path.join(os.tmpdir(), 'kiln-remote-parity-'));
const origin = 'http://127.0.0.1:18427'; // Intercepted by Playwright; no listening server.
const token = 'synthetic-fixture-token';
const model = {id:'fixture-model',label:'Fixture model',provider:'codex',brand:'openai',efforts:['low','high'],supportsFast:true};
const longOutput = '<img src=x onerror="window.xssRan=true">\n' + 'Synthetic output line.\n'.repeat(12000);
const calls = [
  {id:'pending',name:'read_file',input:'{"path":"/fixture/pending.txt"}',isDone:true},
  {id:'running',name:'exec_command',input:'{"command":"fixture command"}',startedAt:100},
  {id:'success',name:'search',input:'{"query":"fixture"}',result:'',startedAt:100,completedAt:102},
  {id:'failure',name:'edit_file',input:'{"path":"/fixture/failure.txt"}',isError:true,result:longOutput},
];
const media = [
  {id:'picture',source:'/fixture/image.png',kind:'image',label:'Fixture image'},
  {id:'sound',source:'/fixture/audio.wav',kind:'audio',label:'Fixture audio'},
  {id:'video',source:'/fixture/video.mp4',kind:'video',label:'Fixture video'},
  {id:'document',source:'/fixture/document.pdf',kind:'document',label:'Fixture document'},
  {id:'remote',source:'https://media.example.test/picture.png',kind:'image',label:'Remote fixture image'},
  {id:'link',source:'https://www.youtube.com/watch?v=fixture',kind:'link',provider:'YouTube',label:'Fixture embed'},
];
const baseMessages = [
  {id:'user',role:'user',blocks:[{type:'text',text:'Synthetic tool timeline verification.'}]},
  {id:'media',role:'assistant',blocks:[{type:'text',text:'Synthetic media receipt.',media}]},
  {id:'history',role:'assistant',blocks:[
    {type:'toolUse',tool:{id:'unknown',name:'unknown_receipt',input:'{}',isDone:true}},
    {type:'text',text:'Prose separates tool groups.'},
    {type:'toolUse',tool:{id:'paired',name:'read_file',input:'{}'}},
    {type:'toolResult',toolUseId:'paired',content:'Paired result',isError:false},
    {type:'toolResult',toolUseId:'orphan',content:'Orphan result',isError:true},
  ]},
];
const data = {
  activeSessionId:'fixture',
  sessions:[{id:'fixture',name:'Synthetic timeline',kind:'code',model:model.id,workDir:'/fixture',messageCount:3,tags:[]},
    {id:'other',name:'Other fixture',kind:'chat',model:model.id,workDir:'/fixture',messageCount:1,tags:[]}],
  messages:structuredClone(baseMessages),
  live:{isBusy:true,thinkingText:'Synthetic reasoning summary.',streamingText:'Synthetic response in progress.',activeToolCalls:structuredClone(calls)},
  toolbar:{sessionMode:'build',permissionMode:'ask',effortLevel:'high',thinkingEnabled:true,openAIFastMode:false},
  usage:{inputTokens:9000000,outputTokens:1234,totalCost:0},
  context:{usedTokens:31246,window:380000},
  settings:{themeMode:'dark',defaultWorkDir:'/fixture',userDisplayName:'Fixture user',sendKey:'enter',thinkingCollapsedByDefault:true},
  models:[model],
};

// A real playable PCM buffer, generated in memory without external media files.
const wav = Buffer.alloc(44 + 8000 * 2 * 60);
wav.write('RIFF');wav.writeUInt32LE(wav.length - 8,4);wav.write('WAVEfmt ',8);
wav.writeUInt32LE(16,16);wav.writeUInt16LE(1,20);wav.writeUInt16LE(1,22);
wav.writeUInt32LE(8000,24);wav.writeUInt32LE(16000,28);wav.writeUInt16LE(2,32);wav.writeUInt16LE(16,34);
wav.write('data',36);wav.writeUInt32LE(wav.length - 44,40);
const reports = [], errors = [], foreign = [], requests = [];
let failSend = true;
const pass = name => {reports.push(name);console.log('PASS:',name);};

(async()=>{
  const browser = await chromium.launch({headless:true,channel:process.env.KILN_BROWSER_CHANNEL || 'chrome'});
  // All responses are fixture-controlled. Playwright's SW-blocking init script
  // itself throws in opaque-origin sandboxed document previews.
  const context = await browser.newContext({viewport:{width:1440,height:1000},colorScheme:'dark',permissions:['clipboard-read','clipboard-write']});
  const page = await context.newPage();page.setDefaultTimeout(10000);
  page.on('pageerror',e=>errors.push(e.message));
  await context.route('**/*',async route=>{
    const request=route.request(),url=new URL(request.url()),headers=await request.allHeaders();
    if(url.origin!==origin){
      foreign.push({url:url.href,authorization:headers.authorization,referer:headers.referer});
      if(url.hostname==='media.example.test')return route.fulfill({contentType:'image/png',body:png});
      if(url.hostname==='www.youtube-nocookie.com')return route.fulfill({contentType:'text/html',body:'<!doctype html><p>Synthetic embedded player</p>'});
      return route.abort();
    }
    if(url.pathname==='/')return route.fulfill({contentType:'text/html',body:html});
    requests.push(url.pathname);
    if(url.pathname.startsWith('/api/')&&headers.authorization!=='Bearer '+token&&url.searchParams.get('t')!==token){
      return route.fulfill({status:401,contentType:'application/json',body:'{"error":"Fixture access denied"}'});
    }
    if(url.pathname==='/api/media'){
      const id=url.searchParams.get('id');
      if(id==='picture')return route.fulfill({contentType:'image/png',body:png});
      if(id==='sound')return route.fulfill({contentType:'audio/wav',body:wav});
      if(id==='document')return route.fulfill({contentType:'text/plain',body:'Synthetic document fixture'});
      return route.fulfill({status:404,body:'Synthetic missing video'});
    }
    const body=request.postDataJSON()||{};let result={},status=200;
    if(url.pathname==='/api/state')result=data;
    else if(url.pathname==='/api/link-preview')result={title:'Fixture embed',embedURL:'https://www.youtube-nocookie.com/embed/fixture',height:200};
    else if(url.pathname==='/api/remote')result={accessLevel:'loopback',urls:{},tailscale:{status:'absent'}};
    else if(url.pathname==='/api/settings')result=data.settings;
    else if(url.pathname==='/api/settings/chat'){Object.assign(data.settings,body);result=data.settings;}
    else if(url.pathname==='/api/toolbar'){Object.assign(data.toolbar,body);result=data.toolbar;}
    else if(url.pathname==='/api/model')data.sessions[0].model=body.model;
    else if(url.pathname==='/api/select')data.activeSessionId=body.sessionId;
    else if(url.pathname==='/api/send'){if(failSend){status=409;result={error:'Synthetic rejection'};}}
    else if(url.pathname==='/api/interrupt')data.live.isBusy=false;
    else if(url.pathname==='/api/retry'){data.live.isBusy=true;result={status:'queued'};}
    else if(url.pathname==='/api/redirect')return route.fulfill({status:302,headers:{location:'https://media.example.test/blocked'}});
    else {status=404;result={error:'Unknown fixture route'};}
    return route.fulfill({status,contentType:'application/json',body:JSON.stringify(result)});
  });
  const poll=()=>page.evaluate(async()=>{
    while(refreshing)await new Promise(resolve=>setTimeout(resolve,10));
    await refreshAll();
  });
  const call=id=>page.locator('[data-tool-id="'+id+'"]');
  try{
    await page.goto(origin+'/?t='+token);
    await page.getByRole('heading',{name:'Synthetic timeline'}).waitFor();
    if(process.argv.includes('--scoped-tools')){
      const tools=label=>[
        {id:'item_0',name:'exec_command',input:'{}',result:(label+' receipt\n').repeat(3000)},
        {id:'item_1',name:'read_file',input:'{}',result:label+' second receipt'},
      ];
      const response=(id,label)=>({id,role:'assistant',blocks:tools(label).map(tool=>({type:'toolUse',tool}))});
      const emptyLive={isBusy:false,streamingText:'',thinkingText:'',activeToolCalls:[]};
      const aID='11111111-1111-4111-8111-111111111111',bID='22222222-2222-4222-8222-222222222222';
      data.messages=[response(aID,'A'),response(bID,'B')];data.live=emptyLive;await poll();
      const a=page.locator('[data-message="'+aID+'"]'),b=page.locator('[data-message="'+bID+'"]');
      const groupIn=row=>row.locator('.tool-group-disclosure');
      const firstCall=row=>row.locator('[data-tool-id="item_0"]');
      const resultIn=row=>firstCall(row).locator('.tool-result-disclosure');
      const expand=async row=>{
        await groupIn(row).locator(':scope > summary').click();
        await firstCall(row).locator(':scope > summary').click();
        await resultIn(row).locator(':scope > summary').click();
      };
      await expand(a);
      await resultIn(a).getByRole('button',{name:'Show more'}).click();await poll();
      assert.equal(await groupIn(b).getAttribute('open'),null,'Same-ID legacy response group remains closed');
      await groupIn(b).locator(':scope > summary').click();
      assert.equal(await firstCall(b).getAttribute('open'),null,'Same-ID call disclosure is independent');
      await firstCall(b).locator(':scope > summary').click();
      assert.equal(await resultIn(b).getAttribute('open'),null,'Same-ID output disclosure is independent');
      await resultIn(b).locator(':scope > summary').click();
      assert.equal((await resultIn(b).locator('pre').textContent()).length,8000);
      assert.equal((await resultIn(a).locator('pre').textContent()).length,16000);
      await resultIn(b).getByRole('button',{name:'Copy full output'}).click();
      assert.equal(await page.evaluate(()=>navigator.clipboard.readText()),tools('B')[0].result);
      await firstCall(a).locator(':scope > summary').click();await poll();
      assert.equal(await firstCall(b).getAttribute('open'),'');
      pass('two legacy UUID responses with identical tool IDs keep group/call/output expansion, limits and receipts independent');

      data.messages.push({id:'u1',role:'user',blocks:[{type:'text',text:'Synthetic turn one'}]});
      data.live={...emptyLive,isBusy:true,activeToolCalls:tools('live')};await poll();
      const liveRow=page.locator('[data-node-key="live"]');
      await expand(liveRow);await resultIn(liveRow).getByRole('button',{name:'Show more'}).click();
      const liveKey=await firstCall(liveRow).getAttribute('data-node-key');
      data.messages.push(response('assistant:u1','live'));data.live=emptyLive;await poll();
      const finalRow=page.locator('[data-message="assistant:u1"]');
      assert.equal(await firstCall(finalRow).getAttribute('data-node-key'),liveKey);
      assert.equal(await groupIn(finalRow).getAttribute('open'),'');
      assert.equal(await firstCall(finalRow).getAttribute('open'),'');
      assert.equal(await resultIn(finalRow).getAttribute('open'),'');
      assert.equal((await resultIn(finalRow).locator('pre').textContent()).length,16000);
      data.messages.push({id:'u2',role:'user',blocks:[{type:'text',text:'Synthetic turn two'}]});
      data.live={...emptyLive,isBusy:true,activeToolCalls:tools('live')};await poll();
      assert.equal(await groupIn(liveRow).getAttribute('open'),null,'New user turn does not inherit completed state');
      await expand(liveRow);
      assert.equal((await resultIn(liveRow).locator('pre').textContent()).length,8000);
      data.messages.push({id:'u3',role:'user',blocks:[{type:'text',text:'Synthetic turn three'}]});await poll();
      assert.equal(await groupIn(liveRow).getAttribute('open'),null,'Changed live scope invalidates identical-content render cache');
      assert.equal(await resultIn(finalRow).getAttribute('open'),'');
      pass('assistant:last-user namespace preserves live-to-final state and isolates subsequent turns, including cached identical live content');

      data.messages.push({id:'m2',role:'assistant',blocks:[{type:'thinking',text:'Synthetic reasoning'},{type:'text',text:'Synthetic prose'},{type:'toolUse',tool:tools('compat')[0]}]});
      data.live=emptyLive;await poll();
      const legacy=page.locator('[data-disclosure="m2:2"]');
      await legacy.locator(':scope > summary').click();assert.equal(await legacy.getAttribute('open'),'');
      assert.deepEqual(errors,[]);
      pass('retained m2:2 disclosure selector remains operable');
      fs.writeFileSync(path.join(output,'results.json'),JSON.stringify({passed:reports,errors},null,2));
      console.log('ARTIFACTS:',output);return;
    }
    assert.equal(await call('unknown').getAttribute('data-status'),'unconfirmed');
    assert.equal(await page.locator('[data-node-key="live"] .tool-call').count(),1,'Collapsed live group shows latest active call only');
    const group=page.locator('[data-node-key="live"] .tool-group-disclosure');
    await group.locator(':scope > summary').focus();await page.keyboard.press('Enter');
    assert.equal(await group.locator(':scope > summary').getAttribute('aria-expanded'),'true');
    for(const [id,status] of [['pending','pending'],['running','running'],['success','success'],['failure','failure']]){
      assert.equal(await call(id).getAttribute('data-status'),status);
    }
    assert.equal(await call('success').locator('.tool-duration').innerText(),'2.0s');
    assert.deepEqual(await page.evaluate(()=>[
      toolStatus({startedAt:0},true),toolStatus({completedAt:0},true),
      toolStatus({startedAt:'100',isDone:true},true),toolStatus({result:''},false),
    ]),['running','success','pending','success'],'Timing fields are numeric UNIX seconds, including zero');
    assert.equal(await call('pending').locator('.tool-output').count(),0,'Collapsed inputs are not rendered');
    const history=page.locator('[data-message="history"]');
    assert.equal(await history.locator('.transcript-row').count(),3,'Prose keeps adjacent groups separate');
    await history.locator('.tool-group-disclosure > summary').click();
    assert.equal(await call('paired').getAttribute('data-status'),'success');
    assert.equal(await call('orphan').getAttribute('data-status'),'failure');
    pass('receipt statuses, isDone boundary, paired/orphan results, adjacent grouping and keyboard expansion');

    await call('failure').locator(':scope > summary').click();
    await call('failure').locator('.tool-result-disclosure > summary').focus();await page.keyboard.press('Space');
    const receipt=call('failure').locator('.tool-result-disclosure .tool-output');
    assert.equal((await receipt.locator('pre').textContent()).length,8000);
    assert(await receipt.locator('pre').evaluate(el=>el.clientHeight<=200&&el.scrollHeight>el.clientHeight));
    assert.equal(await receipt.locator('img,script').count(),0);
    assert.equal(await page.evaluate(()=>window.xssRan),undefined);
    await receipt.getByRole('button',{name:'Copy full output'}).click();
    assert.equal(await page.evaluate(()=>navigator.clipboard.readText()),longOutput);
    assert(await page.evaluate(async()=>{
      const descriptor=Object.getOwnPropertyDescriptor(navigator,'clipboard'),exec=document.execCommand;
      let copied='';
      Object.defineProperty(navigator,'clipboard',{configurable:true,value:undefined});
      document.execCommand=command=>{if(command==='copy'){copied=document.activeElement.value;return true;}return false;};
      try{return await copyToClipboard('Synthetic insecure-context receipt')&&copied==='Synthetic insecure-context receipt';}
      finally{if(descriptor)Object.defineProperty(navigator,'clipboard',descriptor);else delete navigator.clipboard;document.execCommand=exec;}
    }),'HTTP LAN clipboard fallback retains the receipt');
    for(let i=0;i<3;i++)await receipt.getByRole('button',{name:'Show more'}).click();
    assert.equal((await receipt.locator('pre').textContent()).length,32000);
    assert.equal(await receipt.getByRole('button',{name:'Show more'}).count(),0);
    await receipt.locator('pre').evaluate(el=>{el.scrollTop=410;window.receiptNode=el;});
    await page.evaluate(()=>{window.groupNode=document.querySelector('[data-node-key="live"] .tool-list');window.groupNode.scrollTop=150;});
    data.live.streamingText+=' More synthetic text.';await poll();
    assert(await receipt.locator('pre').evaluate(el=>el===window.receiptNode&&el.scrollTop===410));
    assert(await page.evaluate(()=>window.groupNode===document.querySelector('[data-node-key="live"] .tool-list')&&window.groupNode.scrollTop===150));
    assert.equal(await page.locator('#followBtn').getAttribute('aria-pressed'),'false');
    pass('bounded lazy outputs, full-copy receipt, XSS escaping, nested scroll/node/disclosure polling stability');

    const reasoning=page.locator('[data-node-key="live"] .reasoning-disclosure');
    assert.equal(await reasoning.locator('.reasoning-state').innerText(),'Complete','Answer streaming completes reasoning');
    await reasoning.locator(':scope > summary').click();
    data.live.thinkingText+=' Another synthetic thought.';await poll();
    assert.equal(await reasoning.locator(':scope > summary').getAttribute('aria-expanded'),'true');
    assert((await reasoning.locator('pre').innerText()).endsWith('Another synthetic thought.'));
    await page.screenshot({path:path.join(output,'desktop-expanded.png')});

    data.live.activeToolCalls.push({...calls[1],result:'Done',completedAt:103});await poll();
    assert.equal(await call('running').count(),1,'Same-ID update does not duplicate call');
    assert.equal(await call('running').getAttribute('data-status'),'success');
    const savedTools=data.live.activeToolCalls;
    data.live.activeToolCalls=Array.from({length:125},(_,i)=>({id:'page-'+i,name:'read_file',input:'{}',result:'Synthetic result '+i}));
    await poll();
    await page.locator('[data-node-key="live"] .tool-group-disclosure > summary').click();
    assert.equal(await page.locator('[data-node-key="live"] .tool-call').count(),40);
    assert.equal(await page.locator('[data-node-key="live"] .tool-pager span').innerText(),'86-125 of 125');
    await page.getByRole('button',{name:'Earlier tool calls'}).click();
    assert.equal(await page.locator('[data-node-key="live"] .tool-pager span').innerText(),'46-85 of 125');
    assert(await page.locator('[data-node-key="live"] .tool-list').evaluate(el=>el.clientHeight<=288));
    pass('reasoning updates, same-ID deduplication, 40-call pagination and bounded group viewport');

    data.live.activeToolCalls=savedTools;await poll();
    await page.locator('[data-link="link"] .link-load').click();
    await page.locator('[data-link="link"] iframe').waitFor();
    await page.evaluate(()=>{
      window.playerNode=document.querySelector('[data-link="link"] iframe');
      window.imageNode=document.querySelector('[data-media="picture"] img');
      window.videoNode=document.querySelector('[data-media="video"] video');
      window.documentNode=document.querySelector('[data-media="document"] iframe');
    });
    await page.locator('[data-media="sound"] audio').evaluate(async el=>{el.muted=true;el.loop=true;await el.play();el.currentTime=1;window.audioNode=el;});
    await page.waitForFunction(()=>window.audioNode.currentTime>=1&&!window.audioNode.seeking);
    data.messages[1].blocks[0].text+=' Changed prose in the SAME message.';
    data.messages[1].blocks.unshift({type:'thinking',text:'Synthetic inserted reasoning block.'});
    data.messages[1].blocks.push({type:'toolUse',tool:{id:'media-tool',name:'read_file',input:'{}',result:'Media tool updated'}});
    await poll();
    const audioState=await page.evaluate(()=>({same:window.audioNode===document.querySelector('audio'),paused:window.audioNode.paused,time:window.audioNode.currentTime,ended:window.audioNode.ended}));
    assert(audioState.same&&!audioState.paused&&audioState.time>=0.95,JSON.stringify(audioState));
    assert(await page.evaluate(()=>window.playerNode===document.querySelector('[data-link="link"] iframe')&&window.imageNode===document.querySelector('[data-media="picture"] img')&&window.videoNode===document.querySelector('video')&&window.documentNode===document.querySelector('[data-media="document"] iframe')));
    await page.locator('audio').evaluate(el=>el.pause());
    assert.equal(await page.locator('audio[autoplay],video[autoplay]').count(),0);
    pass('same-message audio playback/seek and image/video/document/embed identity survive polling');

    data.messages=Array.from({length:180},(_,i)=>({id:'long-'+i,role:i%2?'assistant':'user',blocks:[{type:'text',text:'Synthetic long conversation row '+i+'\n\n'+'Fixture text. '.repeat(25)}]})).concat(data.messages);
    await poll();
    await page.locator('[data-message="long-75"]').scrollIntoViewIfNeeded();
    const before=await page.locator('[data-message="long-75"]').evaluate(el=>el.getBoundingClientRect().top);
    data.messages[0].blocks[0].text+='\n\n'+'Earlier row growth.\n\n'.repeat(35);
    data.live.streamingText+=' Poll growth.';await poll();
    const after=await page.locator('[data-message="long-75"]').evaluate(el=>el.getBoundingClientRect().top);
    assert(Math.abs(after-before)<=1,'Visible anchor survives earlier row growth');
    const scroll=await page.locator('#messages').evaluate(el=>el.scrollTop);
    await page.waitForTimeout(2100); // Exercise the real installed poll interval once.
    assert.equal(await page.locator('#messages').evaluate(el=>el.scrollTop),scroll);
    assert.equal(await page.locator('#followBtn').getAttribute('aria-pressed'),'false');
    pass('183-message history anchor and real timer polling without jumping to live output');

    // A selection in the old session must not prevent clearing it on a session switch.
    await page.evaluate(()=>{
      const range=document.createRange();range.selectNodeContents(document.querySelector('[data-message="long-75"] .block-text'));
      const selection=getSelection();selection.removeAllRanges();selection.addRange(range);
    });
    data.activeSessionId='other';data.messages=[{id:'other-only',role:'assistant',blocks:[{type:'toolUse',tool:calls[3]}]}];
    data.live={isBusy:false,streamingText:'',thinkingText:'',activeToolCalls:[]};await poll();
    assert.equal(await page.locator('[data-message="long-75"]').count(),0);
    assert.equal(await call('failure').getAttribute('open'),null,'Same call ID in different session starts closed');
    await page.evaluate(()=>getSelection().removeAllRanges());
    data.activeSessionId='fixture';data.messages=structuredClone(baseMessages);
    data.messages.push({id:'assistant:user',role:'assistant',blocks:[{type:'thinking',text:'Completed synthetic summary.'},...calls.map(tool=>({type:'toolUse',tool}))]});
    await poll();
    assert.equal(await page.locator('[data-node-key="live"]').count(),0);
    const completeGroup=page.locator('[data-message="assistant:user"] .tool-group-disclosure');
    assert.equal(await completeGroup.getAttribute('open'),'','Group expansion survives completion by tool identity');
    assert.equal(await call('pending').getAttribute('data-status'),'unconfirmed');
    assert.equal(await page.locator('[data-message="assistant:user"] .reasoning-state').innerText(),'Complete');
    pass('session isolation despite selection, completion lifecycle, tool disclosure continuity');

    assert((await page.locator('#contextInfo').innerText()).includes('8%'));
    assert((await page.locator('#contextInfo').getAttribute('title')).includes('31,246 / 380,000'));
    data.context=null;await poll();assert.equal(await page.locator('#contextInfo').innerText(),'Context unavailable');
    data.context={usedTokens:0,window:380000};await poll();assert((await page.locator('#contextInfo').innerText()).includes('0%'));
    data.context={usedTokens:31246,window:380000};await poll();
    assert.equal(await page.locator('.composer-options #chatHdrModel').count(),1);
    await page.getByLabel('Reasoning',{exact:true}).selectOption('low');
    await page.getByRole('button',{name:'Fast mode'}).click();
    await page.getByRole('textbox',{name:'Message',exact:true}).fill('Synthetic recoverable draft');
    await page.getByRole('button',{name:'Send',exact:true}).click();
    await page.getByRole('alert').filter({hasText:'Synthetic rejection'}).waitFor();
    assert.equal(await page.getByRole('textbox',{name:'Message',exact:true}).inputValue(),'Synthetic recoverable draft');
    failSend=false;await page.getByRole('button',{name:'Send',exact:true}).click();
    await page.waitForFunction(()=>document.getElementById('composerInput').value==='');
    data.live={isBusy:true,streamingText:'',thinkingText:'',activeToolCalls:[]};await poll();
    assert.equal(await page.locator('.run-lifecycle').innerText(),'Working');
    await page.getByRole('button',{name:'Stop',exact:true}).click();await poll();
    assert.equal(await page.locator('.run-lifecycle').count(),0);
    data.live.lastError='Synthetic stopped-run failure';await poll();
    assert.equal(await page.locator('.err-row[role="alert"]').innerText(),'Synthetic stopped-run failure');
    assert.equal(await page.getByRole('button',{name:'Retry last request'}).isEnabled(),true);
    pass('measured context exactness, composer controls, rejected/sent draft, working/stop/error lifecycle');

    for(const width of [1100,900,390,320]){
      await page.setViewportSize({width,height:844});
      await completeGroup.scrollIntoViewIfNeeded();
      assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'Page fits '+width);
      assert(await page.locator('.composer-options').evaluate(el=>el.scrollWidth<=el.clientWidth),'Composer fits '+width);
      assert(await page.locator('#messages').evaluate(el=>el.scrollWidth<=el.clientWidth),'Transcript fits '+width);
    }
    await page.setViewportSize({width:390,height:844});
    await completeGroup.scrollIntoViewIfNeeded();
    await page.screenshot({path:path.join(output,'mobile-expanded.png')});
    data.settings.themeMode='light';await poll();await page.screenshot({path:path.join(output,'mobile-light.png')});
    await page.emulateMedia({reducedMotion:'reduce'});
    data.live={isBusy:true,streamingText:'',thinkingText:'Synthetic active reasoning.',activeToolCalls:[calls[1]]};await poll();
    const runningIcon=page.locator('[data-node-key="live"] .tool-state svg');
    await runningIcon.scrollIntoViewIfNeeded();
    assert.equal(await runningIcon.evaluate(el=>getComputedStyle(el).animationName),'none');
    assert.equal(await page.locator('[data-node-key="live"] .reasoning-state').innerText(),'Working');
    await page.getByRole('button',{name:'Sessions',exact:true}).click();
    await page.getByRole('button',{name:'Settings',exact:true}).waitFor({state:'visible'});
    await page.getByRole('button',{name:'Close panels'}).click({position:{x:375,y:100}});
    pass('desktop/tablet/390px/320px layout, mobile panels, light theme and reduced motion');

    const traceDetail=('<img src=x onerror="window.traceXss=true"> Synthetic trace receipt.\n'.repeat(300)).slice(0,16000);
    const traceEntries=Array.from({length:300},(_,index)=>({
      id:'event-'+index,timestamp:1789360000+index,source:'fixture',level:index%9===0?'error':index%5===0?'warning':'info',
      phase:'verification',title:'Synthetic event '+index,detail:traceDetail,metadata:{index:String(index),original:'Unmodified metadata'},
    }));
    const recordedEntries=traceEntries.map(entry=>({...entry,id:'record-'+entry.id}));
    data.messages.push({id:'recorded-trace',role:'assistant',blocks:[
      {type:'text',text:'Before recorded log.'},
      {type:'toolUse',tool:{id:'before-trace',name:'read_file',result:'Before'}},
      {type:'trace',entries:recordedEntries},
      {type:'toolUse',tool:{id:'after-trace',name:'read_file',result:'After'}},
      {type:'text',text:'After recorded log.'},
    ]});
    data.live.streamingText='Synthetic prose after the live log.';await poll();
    await page.evaluate(()=>{
      window.traceTool=document.querySelector('[data-node-key="live"] [data-tool-id="running"]');
      window.traceProse=document.querySelector('[data-node-key="live:text"]');
    });
    data.live.traceEntries=traceEntries;await poll();
    const liveTrace=page.locator('[data-node-key="live"] .trace-block');
    const recordedTrace=page.locator('[data-message="recorded-trace"] .trace-block');
    assert(await page.evaluate(()=>window.traceTool===document.querySelector('[data-node-key="live"] [data-tool-id="running"]')&&window.traceProse===document.querySelector('[data-node-key="live:text"]')),'Arriving trace preserves tool and prose nodes');
    assert.deepEqual(await page.locator('[data-node-key="live"] > .msg').evaluate(el=>[...el.children].map(row=>row.matches('.reasoning-disclosure')?'reasoning':row.matches('.trace-block')?'trace':row.matches('.tool-call')?'tool':'prose')),['reasoning','trace','tool','prose']);
    assert.deepEqual(await page.locator('[data-message="recorded-trace"] > .msg').evaluate(el=>[...el.children].map(row=>row.matches('.trace-block')?'trace':row.matches('.tool-call')?'tool':'prose')),['prose','tool','trace','tool','prose']);
    for(const log of [liveTrace,recordedTrace]){
      assert.equal(await log.locator('.trace-entry,pre,.tool-list').count(),0,'Closed log does not materialize receipts');
      assert((await log.textContent()).length<120,'Closed DOM is independent of 4.8MB of details');
    }
    assert(await page.evaluate(()=>state.live.traceEntries.length===300&&state.live.traceEntries.every(entry=>entry.detail.length===16000)),'Received trace storage is not truncated');
    assert.equal(await page.evaluate(()=>{
      const holder=document.createElement('div');holder.innerHTML=renderBlock({type:'trace',entries:state.messages.find(m=>m.id==='recorded-trace').blocks[2].entries},'legacy-trace');
      return holder.querySelectorAll('.trace-entry,pre').length;
    }),0,'Legacy renderBlock path is lazy too');
    await liveTrace.locator(':scope > summary').focus();await page.keyboard.press('Enter');
    assert.equal(await liveTrace.locator('.trace-entry').count(),40);
    assert.equal(await liveTrace.locator('.tool-pager span').innerText(),'261-300 of 300');
    assert.equal(await liveTrace.locator('pre').count(),0,'Opening group does not render unopened entries');
    await liveTrace.getByRole('button',{name:'Copy full run log'}).click();
    assert.deepEqual(JSON.parse(await page.evaluate(()=>navigator.clipboard.readText())),traceEntries,'Full log copy includes all 300 original receipts');
    const lastEntry=liveTrace.locator('[data-trace-id="event-299"]');
    await lastEntry.locator(':scope > summary').click();
    assert.equal((await lastEntry.locator('pre').textContent()).length,8000);
    assert(await lastEntry.locator('pre').evaluate(el=>el.clientHeight<=200&&el.scrollHeight>el.clientHeight));
    await lastEntry.getByRole('button',{name:'Copy full receipt'}).click();
    assert.deepEqual(JSON.parse(await page.evaluate(()=>navigator.clipboard.readText())),traceEntries[299]);
    await lastEntry.getByRole('button',{name:'Show more'}).click();
    assert.equal((await lastEntry.locator('pre').textContent()).length,16000);
    await lastEntry.getByRole('button',{name:'Show more'}).click();
    assert.equal(await lastEntry.locator('pre').textContent(),JSON.stringify(traceEntries[299],null,2));
    assert.equal(await lastEntry.locator('script,img').count(),0);
    assert.equal(await page.evaluate(()=>window.traceXss),undefined);
    await liveTrace.getByRole('button',{name:'Earlier log entries'}).click();
    assert.equal(await liveTrace.locator('.tool-pager span').innerText(),'221-260 of 300');
    const readingEntry=liveTrace.locator('[data-trace-id="event-250"]');
    await readingEntry.locator(':scope > summary').click();
    await readingEntry.locator('pre').evaluate(el=>{el.scrollTop=110;window.traceReceipt=el;});
    await liveTrace.locator('.tool-list').evaluate(el=>{window.traceList=el;window.traceListScroll=el.scrollTop;});
    traceEntries.push({...traceEntries[0],id:'event-300',title:'Appended synthetic event'});
    data.live.streamingText+=' Poll update.';await poll();
    assert.equal(await liveTrace.locator('.tool-pager span').innerText(),'221-260 of 301','Reading page stays pinned on append');
    assert(await readingEntry.locator('pre').evaluate(el=>el===window.traceReceipt&&el.scrollTop===110));
    assert(await liveTrace.locator('.tool-list').evaluate(el=>el===window.traceList&&el.scrollTop===window.traceListScroll&&el.clientHeight<=288));
    assert.equal(await liveTrace.locator('.trace-entry').count(),40);
    assert((await liveTrace.locator('pre').allTextContents()).reduce((sum,text)=>sum+text.length,0)<=40*32000,'Expanded DOM has a fixed preview ceiling');
    assert.equal(await page.locator('#followBtn').getAttribute('aria-pressed'),'false');
    await page.setViewportSize({width:1440,height:1000});await liveTrace.scrollIntoViewIfNeeded();
    await page.screenshot({path:path.join(output,'trace-desktop.png')});
    await page.setViewportSize({width:390,height:844});await liveTrace.scrollIntoViewIfNeeded();
    assert(await page.locator('#messages').evaluate(el=>el.scrollWidth<=el.clientWidth));
    await page.screenshot({path:path.join(output,'trace-mobile.png')});
    await liveTrace.locator(':scope > summary').click();
    assert.equal(await liveTrace.locator('.trace-entry,pre,.tool-list').count(),0);
    assert.equal(await page.evaluate(()=>state.live.traceEntries.length),301);
    await recordedTrace.locator(':scope > summary').click();
    assert.equal(await recordedTrace.locator('.trace-entry').count(),40);
    assert.equal(await recordedTrace.locator('pre').count(),0);
    data.live={isBusy:false,streamingText:'',thinkingText:'',activeToolCalls:[],traceEntries};await poll();
    assert.equal(await page.locator('[data-node-key="live"] .trace-block').count(),1,'Trace-only terminal state remains visible');
    assert.equal(await liveTrace.locator('.trace-live').count(),0);
    data.settings.thinkingCollapsedByDefault=false;
    data.messages.push({id:'reasoning-default',role:'assistant',blocks:[{type:'thinking',text:'Synthetic default-open reasoning.'}]});await poll();
    const defaultReasoning=page.locator('[data-message="reasoning-default"] .reasoning-disclosure');
    assert.equal(await defaultReasoning.getAttribute('open'),'');
    await defaultReasoning.locator(':scope > summary').click();await poll();
    assert.equal(await defaultReasoning.getAttribute('open'),null,'User closure wins over server default');
    pass('300x16k live/recorded traces: lazy closed DOM, 40-entry paging, original full-copy receipts, bounded previews, order/node/scroll stability and reasoning default');

    assert(await page.evaluate(async()=>{try{await api('https://media.example.test/api/state');return false;}catch{return true;}}));
    assert(await page.evaluate(async()=>{try{await api('/api/redirect');return false;}catch{return true;}}));
    assert(foreign.length>0,'External media/embed request isolation was exercised');
    assert(foreign.every(request=>!request.authorization&&!request.url.includes(token)&&!String(request.referer).includes(token)));
    assert(!foreign.some(request=>request.url.endsWith('/blocked')),'Authenticated redirect never followed');
    const unauth=await context.newPage();await unauth.goto(origin+'/');
    await unauth.waitForFunction(()=>document.body.textContent.includes('Fixture access denied'));await unauth.close();
    assert.equal(await page.evaluate(()=>{
      const fixture=document.createElement('div');fixture.innerHTML=renderBlock({type:'text',text:'<img src=x onerror=alert(1)><script>alert(1)</script>[unsafe](javascript:alert(1))'});
      return fixture.querySelectorAll('script,img,[href^="javascript:"]').length;
    }),0);
    assert.deepEqual(errors,[]);
    pass('same-origin auth, no bearer/query/referrer leakage, blocked redirect, denial and Markdown sanitization');
    fs.writeFileSync(path.join(output,'results.json'),JSON.stringify({passed:reports,errors,foreignRequests:foreign.length,apiRequests:requests.length},null,2));
    console.log('ARTIFACTS:',output);
  }catch(error){
    await page.screenshot({path:path.join(output,'failure.png')});console.error('ARTIFACTS:',output);console.error(error);throw error;
  }finally{await context.close();await browser.close();}
})().catch(error=>{console.error(error);process.exitCode=1;});
