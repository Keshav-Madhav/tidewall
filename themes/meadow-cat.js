// 草地上的小黑猫：贴图只上传一次，位置随种子更换，始终为男孩的整轮路线留空。
let meadowCatScene=null;
function meadowCatSegmentDistance(p,a,b) {
  const dx=b.x-a.x,dy=b.y-a.y;
  const t=Math.max(0,Math.min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/(dx*dx+dy*dy||1)));
  return Math.hypot(p.x-a.x-dx*t,p.y-a.y-dy*t);
}
function meadowCatRunLanes(state,width,height,taskbar) {
  const scale=Math.max(.24,Math.min(1.25,width/1379,(height-taskbar)/1141))*.35;
  const lanes=[];
  const add=(a,b)=>{lanes.push([{...a},{...b}]);return b;};
  const finish=from=>{
    for(let i=0;i<64;i++){
      const to=meadowBoyRunDestination(from,scale,width,height,taskbar);
      add(from,to);from=to;if(to.exit)break;
    }
  };
  // 包含正在进行的那一段，以及之后一直跑出上边缘的各段。
  const current=state.routeTarget?add(state.position,state.routeTarget):state.position;
  finish(current);
  // 下方返回后每轮走同一条路线，预留整轮，而非只避开男孩当前的位置。
  const bottom={x:Math.max(96*scale+12,Math.min(width*.70,width-612*scale-12)),y:height+116*scale+24};
  const y=(height-taskbar)*.70;
  const entry={x:Math.max(96*scale+12,bottom.x-(bottom.y-y)*.65),y};
  add(bottom,entry);finish(entry);
  return {lanes,scale};
}
function meadowCatChoosePlace(state,width,height,taskbar,sceneSeed,desktopIcons,cloudSize,near=null) {
  const {lanes,scale}=meadowCatRunLanes(state,width,height,taskbar);
  const size=Math.max(28,Math.min(90,Math.min(width/1379,(height-taskbar)/1141)*78))*.578;
  const radius=size*.58,pad=radius+12,clearance=radius+96*scale+14;
  if(width<=pad*2||height-taskbar<=pad*2)return null;
  let randomState=(sceneSeed|0)^0x71a43d25;
  const random=()=>{
    randomState=(randomState+0x6d2b79f5)|0;
    let v=Math.imul(randomState^randomState>>>15,1|randomState);
    v^=v+Math.imul(v^v>>>7,61|v);
    return ((v^v>>>14)>>>0)/4294967296;
  };
  let best=null,bestScore=Infinity;
  for(let i=0;i<337;i++){
    const x=i<256?random():((i-256)%9+.5)/9;
    const y=i<256?random():(Math.floor((i-256)/9)+.5)/9;
    const p={x:pad+x*(width-pad*2),y:pad+y*(height-taskbar-pad*2)};
    const routeDistance=Math.min(...lanes.map(([a,b])=>meadowCatSegmentDistance(p,a,b)));
    if(routeDistance<clearance)continue;
    let score=0;
    for(const icon of desktopIcons){
      const dx=Math.max(icon.x-p.x,0,p.x-icon.x-icon.w);
      const dy=Math.max(icon.y-p.y,0,p.y-icon.y-icon.h);
      score+=Math.max(0,radius+cloudSize+25-Math.hypot(dx,dy));
    }
    if(near)score=score*1000+Math.hypot(p.x-near.x,p.y-near.y)+(typeof meadowCloudOver==='function'&&meadowCloudOver(p.x,p.y)?5e5:0);   // (moving: the nearest clear spot)
    if(score<bestScore){best={...p,size,clearance,routeDistance,lanes};bestScore=score;}
    if(score===0&&!near)break;
  }
  return best;
}
function meadowCatTailAngle(time,sceneSeed) {
  const period=10+Math.abs(sceneSeed%4),age=(time+Math.abs(sceneSeed%1300)/1000)%period-3;
  if(age<0||age>=1.6)return 0;
  const t=age/1.6;
  // 大部分时间安静躺着，偶尔柔和地来回摆两下，起止都回到原姿势。
  return Math.sin(t*Math.PI*4)*Math.pow(Math.sin(t*Math.PI),2)*.34;
}
function prepareMeadowCat(boy,now=0) {
  if(!meadowCatScene)meadowCatScene=createMeadowCatScene();
  return meadowCatScene.prepare(boy,now);
}
function createMeadowCatScene() {
  const texture=gl.createTexture();let ready=false,layout='',signature='',routeState=null,place=null;
  let time=0,previousTime=null,at=null,walk=null,coveredFor=0,lastLook=-1;
  // under a window (or on the icons)?
  const covered=(x,y,r)=>typeof icons!=='undefined'&&icons.some(ic=>x+r>ic.x-4&&x-r<ic.x+ic.w+4&&y+r>ic.y-4&&y-r<ic.y+ic.h+4)||
    (typeof meadowCloudOver==='function'&&meadowCloudOver(x,y)&&typeof FB!=='undefined'&&sampleArr(FB.s,x,y)-P.edge<0);   // (or deep in its cloud)
  const image=new Image();
  image.onload=()=>{
    const sprite=document.createElement('canvas');sprite.width=sprite.height=384;
    sprite.getContext('2d').drawImage(image,0,0,384,384);
    gl.activeTexture(gl.TEXTURE8);gl.bindTexture(gl.TEXTURE_2D,texture);
    gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,sprite);
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);ready=true;
  };
  image.onerror=()=>console.warn('草地小猫素材加载失败');
  image.src='assets/meadow-black-kitten.png';
  return {prepare(boy,now){
    if(previousTime!==null)time+=Math.max(0,Math.min(.05,(now-previousTime)/1000));
    previousTime=now;
    const nextLayout=[W,H,TASKBAR].join(',');
    if(layout!==nextLayout){layout=nextLayout;routeState=null;place=null;signature='';}
    if(boy&&boy.state.layout===layout)routeState=boy.state;
    // 等知道窗口在哪了再选位置（wallpaper: the first windows message), not on an empty desktop it then gets crowded on
    if(!ready||!routeState||(typeof iconsSeen!=='undefined'&&!iconsSeen))return null;
    const next=[layout,seed].join(',');
    if(next!==signature){
      signature=next;place=meadowCatChoosePlace(routeState,W,H,TASKBAR,seed,icons,P.sigma);at=place&&{x:place.x,y:place.y};walk=null;coveredFor=0;
    }
    if(!place)return null;
    const dt=lastLook<0?0:Math.max(0,Math.min(.05,time-lastLook));lastLook=time;
    // a window settled over her: after a moment she gets up and pads off to the nearest clear spot (never a jump)
    if(!walk){
      coveredFor=covered(at.x,at.y,place.size*.45)?coveredFor+dt:0;
      if(coveredFor>.6){
        coveredFor=0;
        const to=meadowCatChoosePlace(routeState,W,H,TASKBAR,seed,icons,P.sigma,at);
        if(to&&Math.hypot(to.x-at.x,to.y-at.y)>6){
          const d=Math.hypot(to.x-at.x,to.y-at.y);
          walk={from:{...at},to:{x:to.x,y:to.y},t:0,T:Math.max(1,Math.min(4,d/90))};place={...place,...to,size:place.size};
        }
      }
    }
    let hop=0;
    if(walk){
      walk.t+=dt;const u=Math.min(1,walk.t/walk.T),e=u*u*(3-2*u),d=Math.hypot(walk.to.x-walk.from.x,walk.to.y-walk.from.y);
      at={x:walk.from.x+(walk.to.x-walk.from.x)*e,y:walk.from.y+(walk.to.y-walk.from.y)*e};
      hop=Math.abs(Math.sin(e*d/9*Math.PI))*Math.min(1,u*6,(1-u)*6)*place.size*.06;   // a little trot
      if(window.__twSettle)window.__twSettle(150);
      if(u>=1)walk=null;
    }
    window.__meadowCat={x:at.x,y:at.y,walking:!!walk};
    const size=place.size,rect=[at.x-size/2,at.y-size/2-hop,size,size],shadow=[size*.045,size*.06+hop];
    return {texture,rect,shadow,tail:walk?.18*Math.sin(time*9):meadowCatTailAngle(time,seed),bounds:[rect[0]-2,rect[1]-2,size+shadow[0]+4,size+shadow[1]+4],state:place};
  }};
}
