// Generate provider fixtures with the opt-in RichLinkTests first (see README).
const fs=require('node:fs');
const path=require('node:path');
const http=require('node:http');
const assert=require('node:assert/strict');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'..'),assets=path.join(root,'Sources/App/Resources/remote');
const read=name=>fs.readFileSync(path.join(assets,name),'utf8');
const fixtures=JSON.parse(fs.readFileSync(path.join(root,'.tmp/rich-link-fixtures.json'),'utf8'));
const html=read('index.html').replace('/*STYLES*/',()=>read('remote.css')).replace('/*APPLICATION*/',()=>read('remote.js'))
 .replace('<!--VENDOR-->',()=>['purify.min.js','marked.umd.js','lucide.min.js'].map(f=>'<script>'+read('vendor/'+f)+'</script>').join('\n'))
 .replaceAll('__OPENAI_LOGO__','data:image/png;base64,'+fs.readFileSync(path.join(root,'Sources/App/Resources/brands/OpenAI-white-monoblossom.png')).toString('base64'));
const data={activeSessionId:'links',sessions:[{id:'links',name:'Rich link previews',kind:'chat',model:'gpt-5.5',workDir:'/tmp',messageCount:1}],messages:[{id:'reply',role:'assistant',assistantName:'GPT-5.5',blocks:[{type:'text',text:'YouTube, Twitter / X, and other shared links.',media:fixtures}]}],live:{isBusy:false,streamingText:'',activeToolCalls:[]},toolbar:{},usage:{},settings:{themeMode:'dark'},models:[]};
let requests=0;
const server=http.createServer((req,res)=>{
 const url=new URL(req.url,'http://localhost');
 if(url.pathname==='/'){res.setHeader('Content-Type','text/html');res.end(html);return;}
 res.setHeader('Content-Type','application/json');
 if(url.pathname==='/api/state'){res.end(JSON.stringify(data));return;}
 if(url.pathname==='/api/link-preview'){
  requests++;const entry=fixtures.find(f=>f.id===url.searchParams.get('id'));
  if(!entry){res.statusCode=404;res.end('{}');return;}res.end(JSON.stringify(entry));return;
 }
 res.end('{}');
});
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await chromium.launch({headless:true,channel:process.env.KILN_BROWSER_CHANNEL||'chrome'});
 const page=await browser.newPage({viewport:{width:1440,height:1000},colorScheme:'dark'});
 page.setDefaultTimeout(15000);
 const errors=[];page.on('pageerror',error=>errors.push(error.message));
 page.on('console',message=>{if(message.type()==='error')console.log('Console:',message.text());});
 page.on('requestfailed',request=>console.log('Failed request:',request.url(),request.failure()?.errorText));
 try{
  // Deterministic mode tests UI and isolation without relying on live widget availability.
  if(process.env.KILN_LIVE_EMBED_TESTS!=='1'){
   await page.route('https://**/*',async route=>{
    if(route.request().resourceType()==='image'){
     await route.fulfill({contentType:'image/png',body:fs.readFileSync(path.join(root,'Sources/App/Resources/brands/OpenAI-white-monoblossom.png'))});
    }else{await route.fulfill({contentType:'text/html',body:'<!doctype html><title>Provider fixture</title><p>Embedded player fixture</p>'});}
   });
  }
  await page.goto('http://127.0.0.1:'+server.address().port+'/?t=fixture-secret');
  await page.getByRole('heading',{name:'Rich link previews'}).waitFor();
  assert.equal(await page.locator('.rich-link').count(),6);
  assert.equal(await page.locator('.link-player iframe').count(),0,'Widgets must not load before interaction');
  const youtube=page.locator('[data-provider="YouTube"]');
  await youtube.scrollIntoViewIfNeeded();
  await page.waitForFunction(()=>document.querySelector('[data-provider="YouTube"] .link-title').textContent.includes('YouTube Developers'));
  await youtube.getByRole('button',{name:'Load YouTube embed'}).click();
  const frame=youtube.locator('iframe');await frame.waitFor();
  assert((await frame.getAttribute('src')).includes('youtube-nocookie.com/embed/M7lc1UVf-VE?autoplay=0'));
  assert.equal(await frame.getAttribute('referrerpolicy'),'strict-origin-when-cross-origin');
  assert(!(await frame.getAttribute('src')).includes('fixture-secret'));
  await frame.evaluate(el=>window.keptPlayer=el);
  data.live.isBusy=true;data.live.streamingText='New output';await page.evaluate(()=>refreshAll());
  assert(await frame.evaluate(el=>el===window.keptPlayer),'Player retained during polling');
  await page.screenshot({path:path.join(root,'.tmp/rich-links-youtube-desktop.png')});
  if(process.env.KILN_LIVE_EMBED_TESTS==='1'){
   const providerFrame=await (await frame.elementHandle()).contentFrame();
   await providerFrame.waitForLoadState('domcontentloaded');
   await page.waitForTimeout(6000);
   console.log('YouTube live player:',(await providerFrame.locator('body').innerText()).slice(0,600));
   assert(!/Error 153|error code.?153/i.test(await providerFrame.locator('body').innerText()),'Embedding identity accepted');
   await page.screenshot({path:path.join(root,'.tmp/rich-links-youtube-live.png')});
  }
  await youtube.getByRole('button',{name:'Close embed'}).click();assert.equal(await youtube.locator('iframe').count(),0);
  const twitter=page.locator('[data-provider="Twitter / X"]');await twitter.scrollIntoViewIfNeeded();
  await twitter.getByText("Sunsets don't get much better than this one over @GrandTetonNPS. #nature #sunset",{exact:true}).waitFor();
  assert.equal(await twitter.locator('iframe').count(),0,'FixupX posts use native content, not X widgets');
  assert((await twitter.getByRole('link',{name:'Open on FixupX'}).getAttribute('href')).startsWith('https://fixupx.com/'));
  const postImage=twitter.locator('.inline-media img').first();
  await page.waitForFunction(()=>document.querySelector('[data-provider="Twitter / X"] .inline-media img')?.naturalWidth>0);
  assert(await postImage.isVisible(),'Post photo is displayed');
  assert.equal(await twitter.locator('.inline-media figcaption').first().evaluate(el=>getComputedStyle(el).flexDirection),'row','Post media controls remain in a single row');
  console.log('FixupX post: text, author, photo and link rendered');
  await page.screenshot({path:path.join(root,'.tmp/rich-links-twitter-desktop.png')});
  for(const width of [900,390]){
   await page.setViewportSize({width,height:844});
   await twitter.scrollIntoViewIfNeeded();
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'No overflow at '+width);
  }
  await page.screenshot({path:path.join(root,'.tmp/rich-links-twitter-mobile.png')});

  const before=requests;await page.evaluate(()=>refreshAll());assert.equal(requests,before,'Polling does not reload metadata');
  // Metadata is rendered as text, never interpreted as markup.
  const malicious=fixtures.find(f=>f.provider==='YouTube');malicious.title='<img src=x onerror="window.injected=true">';
  await youtube.locator('.link-retry').evaluate(el=>el.hidden=false);await youtube.getByRole('button',{name:'Retry link preview'}).click();
  await page.waitForFunction(()=>document.querySelector('[data-provider="YouTube"] .link-title').textContent.startsWith('<img'));
  assert.equal(await youtube.locator('.link-title img').count(),0);
  assert.deepEqual(errors,[]);
  console.log('PASS: six provider cards, metadata, click-to-load, isolation, preserved players, close/retry, and desktop/mobile layout.');
 }catch(error){await page.screenshot({path:path.join(root,'.tmp/rich-links-failure.png')});throw error;}
 finally{await browser.close();server.close();}
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});
