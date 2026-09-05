const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..');
const assets = path.join(root, 'Sources/App/Resources/remote');
const read = name => fs.readFileSync(path.join(assets, name), 'utf8');
const logo = fs.readFileSync(path.join(root, 'Sources/App/Resources/brands/OpenAI-white-monoblossom.png')).toString('base64');
const html = read('index.html').replace('/*STYLES*/', () => read('remote.css'))
  .replace('/*APPLICATION*/', () => read('remote.js'))
  .replace('<!--VENDOR-->', () => ['purify.min.js', 'marked.umd.js', 'lucide.min.js'].map(f => '<script>' + read('vendor/' + f) + '</script>').join('\n'))
  .replaceAll('__OPENAI_LOGO__', 'data:image/png;base64,' + logo);
const model = {id:'gpt-6-astra',label:'GPT-6-Astra',provider:'codex',brand:'openai',efforts:['low','medium','high','xhigh','max','ultra'],supportsFast:true,contextWindow:272000};
const data = {
  activeSessionId:'fixture',
  sessions:[{id:'fixture',name:'Kiln workspace redesign',kind:'code',model:model.id,workDir:'/Users/ari/projects/kiln-app',messageCount:4,tags:['design'],updatedAt:1788580000},
    {id:'notes',name:'Release notes and verification',kind:'code',model:'gpt-5.5',workDir:'/Users/ari/projects/kiln-app',messageCount:2,tags:[]}],
  messages:[{id:'m1',role:'user',timestamp:1788580000,blocks:[{type:'text',text:'Bring the web workspace in line with the native client. Keep the useful controls, but give the conversation more room.'}]},
    {id:'m2',role:'assistant',model:model.id,assistantName:model.label,timestamp:1788580030,blocks:[{type:'thinking',text:'Checking the existing navigation, composer controls, and model catalog.'},{type:'text',text:'The workspace now uses a shared layout:\n\n- A focused conversation with a separate model selector\n- A larger writing area with controls underneath\n- Collapsible reasoning and tool output\n\nThe native settings remain the source of truth.'},{type:'toolUse',tool:{id:'t1',name:'read_file',input:'Sources/Views/Chat/ComposerView.swift',result:'Composer controls verified.',isDone:true}},{type:'trace',entries:[{level:'info',title:'Workspace inspected',detail:'Ready for verification.'}]}]},
    {id:'m3',role:'user',timestamp:1788580100,blocks:[{type:'text',text:'Keep Fast mode and reasoning available on smaller screens too.'}]},
    {id:'m4',role:'assistant',model:model.id,assistantName:model.label,timestamp:1788580110,blocks:[{type:'text',text:'Both are available below the composer. The session list and workspace tools move into drawers on mobile.\n\n```swift\nlet preferences = session.composerPreferences\n```'}]}],
  live:{isBusy:false,streamingText:'',thinkingText:'',activeToolCalls:[]},
  toolbar:{sessionMode:'build',permissionMode:'ask',thinkingEnabled:true,effortLevel:'high',openAIFastMode:false},
  usage:{inputTokens:9000000,outputTokens:1400,totalCost:0},
  context:{usedTokens:31246,window:380000},
  settings:{themeMode:'dark',accentHex:'EC4899',defaultWorkDir:'/Users/ari/projects',defaultModel:'gpt-5.5',autoCompactEnabled:true,language:'en',sendKey:'enter',userDisplayName:'ari'},
  models:[model,{...model,id:'gpt-5.5',label:'GPT-5.5'},{...model,id:'gpt-5.3-codex',label:'GPT-5.3-Codex',older:true,supportsFast:false}]
};
let failSend = true;
const mediaFiles = {
  picture: {mime:'image/png', data:fs.readFileSync(path.join(root,'Sources/App/Resources/brands/OpenAI-white-monoblossom.png'))},
  sound: {mime:'audio/wav', data:fs.existsSync(path.join(root,'.tmp/media-fixture.wav')) ? fs.readFileSync(path.join(root,'.tmp/media-fixture.wav')) : null},
  clip: {mime:'video/mp4', data:fs.existsSync(path.join(root,'.tmp/media-fixture.mp4')) ? fs.readFileSync(path.join(root,'.tmp/media-fixture.mp4')) : null}
};
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if(url.pathname === '/') { res.setHeader('Content-Type','text/html'); res.end(html); return; }
  if(url.pathname === '/api/media') {
    const file=mediaFiles[url.searchParams.get('id')];
    if(!file?.data){res.statusCode=404;res.end();return;}
    res.setHeader('Content-Type',file.mime);res.setHeader('Accept-Ranges','bytes');
    let start=0,end=file.data.length-1;
    const match=req.headers.range?.match(/^bytes=(\d+)-(\d*)$/);
    if(match){start=Number(match[1]);if(match[2])end=Math.min(end,Number(match[2]));res.statusCode=206;res.setHeader('Content-Range',`bytes ${start}-${end}/${file.data.length}`);}
    res.setHeader('Content-Length',end-start+1);res.end(file.data.subarray(start,end+1));return;
  }
  let raw=''; for await(const c of req) raw+=c;
  const body=raw?JSON.parse(raw):{};
  res.setHeader('Content-Type','application/json');
  let out={};
  if(url.pathname==='/api/state'||url.pathname==='/api/models/refresh')out=data;
  else if(url.pathname==='/api/settings')out=data.settings;
  else if(url.pathname==='/api/remote')out={accessLevel:'loopback',port:8421,tailscale:{status:'absent'},urls:{}};
  else if(url.pathname==='/api/toolbar'){Object.assign(data.toolbar,body);out=data.toolbar;}
  else if(url.pathname==='/api/settings/chat'){Object.assign(data.settings,body);out=data.settings;}
  else if(url.pathname==='/api/model'){data.sessions[0].model=body.model;out={status:'ok'};}
  else if(url.pathname==='/api/send'){if(failSend){res.statusCode=409;out={error:'Test rejection: draft retained'};}else{out={status:'queued'};}}
  else if(url.pathname==='/api/select'){data.activeSessionId=body.sessionId;}
  else {res.statusCode=404;out={error:'Unknown fixture route'};}
  res.end(JSON.stringify(out));
});

(async()=>{
  await new Promise(r=>server.listen(0,'127.0.0.1',r));
  const browser=await chromium.launch({headless:true,channel:process.env.KILN_BROWSER_CHANNEL || 'chrome'});
  const page=await browser.newPage({viewport:{width:1440,height:1000},colorScheme:'dark'});
  page.setDefaultTimeout(10000);
  const errors=[];page.on('pageerror',e=>{errors.push(e.message);console.error('Browser:',e.message);});
  const output=path.join(root,'.tmp');fs.mkdirSync(output,{recursive:true});
  try {
    await page.goto('http://127.0.0.1:'+server.address().port);
    await page.getByRole('heading',{name:'Kiln workspace redesign'}).waitFor();
    console.log('Loaded workspace');
    assert((await page.locator('#contextInfo').innerText()).includes('8%'),'Context uses latest occupancy, not nine million processed tokens');
    data.context=null;await page.evaluate(()=>refreshAll());
    assert.equal(await page.locator('#contextInfo').innerText(),'Context unavailable');
    data.context={usedTokens:31246,window:380000};await page.evaluate(()=>refreshAll());
    assert.equal(await page.getByRole('button',{name:'Fast mode'}).count(),1);
    await page.getByLabel('Reasoning',{exact:true}).selectOption('ultra');
    await page.waitForFunction(()=>state.toolbar.effortLevel==='ultra');
    await page.getByRole('button',{name:'Fast mode'}).click();
    await page.waitForFunction(()=>state.toolbar.openAIFastMode===true);
    console.log('Verified reasoning and fast controls');
    await page.getByRole('button',{name:'Settings',exact:true}).click();
    await page.getByRole('button',{name:'Chat & Composer',exact:true}).click();
    await page.getByLabel('Auto-compact at 90%').uncheck();
    await page.waitForFunction(()=>state.settings.autoCompactEnabled===false);
    await page.getByRole('button',{name:'Close',exact:true}).click();
    console.log('Verified auto-compact setting');
    await page.locator('#chatHdrModel').click();
    await page.getByRole('searchbox',{name:'Search models'}).fill('5.3');
    assert.equal(await page.locator('.model-option').count(),1);
    await page.getByRole('button',{name:'Close',exact:true}).click();
    await page.locator('[data-disclosure="m2:2"] summary').click();
    await page.waitForTimeout(2200);
    assert.equal(await page.locator('[data-disclosure="m2:2"]').getAttribute('open'),'');
    await page.getByRole('textbox',{name:'Message',exact:true}).fill('A recoverable draft');
    await page.getByRole('button',{name:'Send',exact:true}).click();
    await page.getByRole('alert').filter({hasText:'Test rejection'}).waitFor();
    assert.equal(await page.getByRole('textbox',{name:'Message',exact:true}).inputValue(),'A recoverable draft');
    await page.reload();await page.getByRole('heading',{name:'Kiln workspace redesign'}).waitFor();
    assert.equal(await page.getByRole('textbox',{name:'Message',exact:true}).inputValue(),'A recoverable draft');
    failSend=false;await page.getByRole('button',{name:'Send',exact:true}).click();
    await page.waitForFunction(()=>document.getElementById('composerInput').value==='');
    await page.screenshot({path:path.join(output,'redesign-web-desktop.png')});
    for(const width of [1100,900,390]) {
      await page.setViewportSize({width,height:844});
      assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'No page overflow at '+width);
    }
    await page.getByRole('button',{name:'Sessions',exact:true}).click();
    await page.getByRole('button',{name:'Settings',exact:true}).waitFor({state:'visible'});
    await page.getByRole('button',{name:'Close panels'}).click({position:{x:375,y:100}});
    await page.screenshot({path:path.join(output,'redesign-web-mobile.png')});
    data.settings.themeMode='light';await page.evaluate(()=>refreshAll());
    await page.screenshot({path:path.join(output,'redesign-web-light.png')});
    data.messages.push({id:'media-message',role:'assistant',assistantName:model.label,model:model.id,blocks:[{type:'text',text:'Media preview check',media:[
      {id:'picture',source:'/tmp/picture.png',kind:'image',label:'Image preview'},
      {id:'sound',source:'/tmp/sound.wav',kind:'audio',label:'Audio preview'},
      {id:'clip',source:'/tmp/clip.mp4',kind:'video',label:'Video preview'},
      {id:'missing',source:'/tmp/missing.png',kind:'image',label:'Unavailable image'}
    ]}]});
    await page.evaluate(()=>refreshAll());
    await page.locator('[data-media="picture"]').scrollIntoViewIfNeeded();
    await page.waitForFunction(()=>document.querySelector('[data-media="picture"] img')?.naturalWidth>0);
    await page.locator('[data-media="picture"] img').click();
    await page.locator('.expanded-media-image').waitFor();
    await page.getByRole('button',{name:'Close',exact:true}).click();
    await page.locator('[data-media="missing"]').scrollIntoViewIfNeeded();
    await page.locator('[data-media="missing"] .media-error').waitFor({state:'visible'});
    assert.equal(await page.locator('video[autoplay],audio[autoplay]').count(),0);
    for(const [id,tag] of [['sound','audio'],['clip','video']]) {
      if(!mediaFiles[id].data)continue;
      await page.locator('[data-media="'+id+'"] '+tag).evaluate(el=>el.play());
      await page.waitForFunction(tag=>document.querySelector(tag).currentTime>0.1,tag);
      await page.evaluate(tag=>{window.playingElement=document.querySelector(tag);window.playingElement.currentTime=1;},tag);
      data.live.isBusy=true;data.live.streamingText='A new reply while media plays';
      await page.evaluate(()=>refreshAll());
      assert(await page.evaluate(tag=>window.playingElement===document.querySelector(tag),tag),'Player node survives chat updates');
      assert(await page.evaluate(tag=>document.querySelector(tag).currentTime>=1,tag),'Seeking survives updates');
      await page.locator(tag).evaluate(el=>el.pause());
      data.live.isBusy=false;data.live.streamingText='';
    }
    await page.screenshot({path:path.join(output,'media-web-mobile.png')});
    await page.evaluate(()=>{window.xssRan=false;document.getElementById('messages').innerHTML=renderBlock({type:'text',text:'<img src=x onerror="window.xssRan=true"><script>window.xssRan=true</script>'});});
    assert.equal(await page.evaluate(()=>window.xssRan),false);
    assert.equal(await page.locator('#messages script,#messages img').count(),0);
    assert.deepEqual(errors,[]);
    console.log('PASS: controls, models, settings, disclosures, draft recovery, responsive layout, media previews/errors, playback/seek continuity when fixtures are present, Markdown sanitization.');
  } catch (error) {
    await page.screenshot({path:path.join(output,'redesign-web-failure.png')});
    console.error('Page:',(await page.locator('body').innerText()).slice(0,1800));
    throw error;
  } finally {await browser.close();server.close();}
})().catch(e=>{console.error(e);server.close();process.exitCode=1;});
