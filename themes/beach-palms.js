// 沙滩的五款椰子树，树根更靠沙地内侧；素材和投影仅在初始化时合成。
const BEACH_PALM_STYLES = [
  {file: 'beach-coconut-palm-v2.png', foot: [.454, .98], crown: [9, -84], radius: 80},
  {file: 'beach-coconut-palm-curved.png', foot: [.470, .98], crown: [18, -80], radius: 84, faceSea: true},
  {file: 'beach-coconut-palm-airy.png', foot: [.415, .98], crown: [27, -82], radius: 84},
  {file: 'beach-coconut-palm-windswept.png', foot: [.25, .98], crown: [40, -78], radius: 78, width: 148, height: 138},
  {file: 'beach-coconut-palm-arch.png', foot: [.84, .98], crown: [-45, -65], radius: 70, width: 128, height: 119, size: 1.35, faceSea: true}
];
const beachPalmImages = BEACH_PALM_STYLES.map(style => {
  const image = new Image();image.src = 'assets/' + style.file;return image;
});
let beachPalmsScene = null;
const PALM_CW = 288, PALM_CH = 300;
const BEACH_PALM_VS = `#version 300 es
precision highp float;
uniform vec2 uRes;
uniform vec4 uPalm;
uniform float uPalmMirror;
uniform float uTime;
out vec2 palmUV;
void main() {
  vec2 corner = vec2(float(gl_VertexID & 1), float(gl_VertexID >> 1));
  // (a cell is wider and taller than the tree: room for its shadow, which falls away down and to the right)
  vec2 local = corner * vec2(${PALM_CW}.0, ${PALM_CH}.0) - vec2(112.0, 162.0);
  float a = sin(uTime * .65 + uPalm.w * 2.0) * .008;
  local = mat2(cos(a), sin(a), -sin(a), cos(a)) * local;
  vec2 p = uPalm.xy + local * uPalm.z;
  gl_Position = vec4(p.x / uRes.x * 2.0 - 1.0, 1.0 - p.y / uRes.y * 2.0, 0.0, 1.0);
  // the mirrored trees have their own row: flipping the quad flipped the shadow toward the wrong sun
  palmUV = vec2((corner.x + uPalm.w) / ${BEACH_PALM_STYLES.length}.0, (corner.y + (uPalmMirror < 0.0 ? 1.0 : 0.0)) * .5);
}`;
const BEACH_PALM_FS = `
uniform sampler2D uPalmAtlas;
uniform float uPalmOpacity;
in vec2 palmUV;
void main() {
  vec4 tree = texture(uPalmAtlas, palmUV);
  if (tree.a < .002) discard;
  vec2 p = vec2(gl_FragCoord.x, uRes.y * uScale - gl_FragCoord.y) / uScale + uOff;
  // 飞鸟始终从树冠上方经过。
  for (int i = 0; i < 8; i++) {
    if (float(i) >= uBirdN) break;
    vec4 b = uBird[i];vec2 q = rot(-b.z) * (p - b.xy);
    if (dot(q, q) < 400.0) {vec3 bird = gullSD(q, b.w);if (min(bird.x, bird.y) < .6) discard;}
  }
  float alpha = tree.a * uPalmOpacity;
  o = vec4(tree.rgb * alpha, alpha);
}`;

function makeMaldivesPalmAtlas() {
  const CW = PALM_CW, CH = PALM_CH;
  const atlas = document.createElement('canvas');atlas.width = CW * BEACH_PALM_STYLES.length * 2;atlas.height = CH * 2 * 2;
  const ctx = atlas.getContext('2d');ctx.scale(2, 2);
  for (let row = 0; row < 2; row++) for (let variant = 0; variant < BEACH_PALM_STYLES.length; variant++) {
    const image = beachPalmImages[variant], style = BEACH_PALM_STYLES[variant], mirror = row ? -1 : 1;
    const width = style.width || 168, height = style.height || 156;
    const footX = style.foot[0] * width, footY = style.foot[1] * height;
    // 每种轮廓分别投影；树根位置不随素材的透明留白变化。
    // Tidewall: the shadow falls down and to the right, away from the trunk, as the gulls' and kayaks' do (a crown flipped
    // straight down below the trunk read as a reflection in water); the mirrored tree casts its own
    const shadow = document.createElement('canvas');shadow.width = CW * 2;shadow.height = CH * 2;
    const shadowCtx = shadow.getContext('2d');shadowCtx.scale(2, 2);
    shadowCtx.translate(112, 162);shadowCtx.transform(.85, .06, -.36, -.5, 0, 0);shadowCtx.scale(mirror, 1);
    shadowCtx.drawImage(image, -footX, -footY, width, height);
    shadowCtx.setTransform(1, 0, 0, 1, 0, 0);shadowCtx.globalCompositeOperation = 'source-in';
    shadowCtx.fillStyle = '#3c6257';shadowCtx.fillRect(0, 0, shadow.width, shadow.height);
    ctx.save();ctx.translate(variant * CW, row * CH);
    ctx.beginPath();ctx.rect(0, 0, CW, CH);ctx.clip();
    ctx.save();ctx.globalAlpha = .20;ctx.filter = 'blur(1.2px)';ctx.drawImage(shadow, 0, 0, CW, CH);ctx.restore();
    ctx.save();ctx.globalAlpha = .17;ctx.fillStyle = '#516051';
    ctx.beginPath();ctx.ellipse(112, 162, 4.4, 1.6, 0, 0, Math.PI * 2);ctx.fill();ctx.restore();
    ctx.save();ctx.translate(112, 162);ctx.scale(mirror, 1);ctx.filter = 'saturate(.94) brightness(.98)';
    ctx.drawImage(image, -footX, -footY, width, height);ctx.restore();ctx.restore();
  }
  // 一次性压低黄色与饱和度，保持偏灰的深绿色；不增加每帧的调色开销。
  const pixels = ctx.getImageData(0, 0, atlas.width, atlas.height), rgba = pixels.data;
  for (let i = 0; i < rgba.length; i += 4) {
    if (!rgba[i + 3]) continue;
    let r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    const yellow = Math.max(0, Math.min(1, (r / Math.max(g, 1) - .60) / .35)) * Math.max(0, Math.min(1, (g - b) / 50));
    r *= 1 - yellow * .22;g *= 1 - yellow * .06;b += yellow * 10;
    const gray = r * .2126 + g * .7152 + b * .0722;
    rgba[i] = (gray + (r - gray) * .70) * .97;
    rgba[i + 1] = (gray + (g - gray) * .70) * .97;
    rgba[i + 2] = (gray + (b - gray) * .70) * .97;
  }
  ctx.putImageData(pixels, 0, 0);
  const texture = gl.createTexture();gl.activeTexture(gl.TEXTURE6);gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, atlas);gl.generateMipmap(gl.TEXTURE_2D);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  return texture;
}

function beachPalmClear(x, y, radius) {
  return icons.every(icon => {
    const dx = Math.max(icon.x - 7 - x, 0, x - icon.x - icon.w - 7);
    const dy = Math.max(icon.y - 7 - y, 0, y - icon.y - icon.h - 7);
    return Math.hypot(dx, dy) > radius;
  });
}
// a palm already standing keeps its place while its root is still on the sand band and its crown no deeper under a window
function beachPalmStillGood(q) {
  const shore = sampleArr(FB.s, q.x, q.y), style = BEACH_PALM_STYLES[q.variant];
  if (shore > -18 || shore < -75 || (window.__visible && !__visible(q.x, q.y, 60))) return false;
  const cx = q.cx !== undefined ? q.cx : q.x + style.crown[0] * q.scale * q.mirror, cy = q.cy !== undefined ? q.cy : q.y + style.crown[1] * q.scale;
  return beachPalmClear(q.x, q.y - 16 * q.scale, 10 * q.scale) && beachPalmClear(cx, cy, style.radius * q.scale * .2);
}
// kept: palms already standing that stay (new ones keep clear of them); want: how many more
function chooseMaldivesPalms(kept = [], want = 10) {
  const random = mulberry32((seed ^ 0x41fc72) >>> 0), chosen = [], order = BEACH_PALM_STYLES.map((_, i) => i);
  for (let i = order.length - 1; i > 0; i--) {const j = Math.floor(random() * (i + 1));[order[i], order[j]] = [order[j], order[i]];}
  const styleRandom = mulberry32((seed ^ 0x6ac309) >>> 0);
  while (order.length < 10) order.push(Math.floor(styleRandom() * BEACH_PALM_STYLES.length));
  // 在整片合适的沙地中均匀抽选，不偏向同一条等距岸线；固定种子避免每帧跳动。
  for (const variant of order) {
    if (chosen.length >= want) break;
    const style = BEACH_PALM_STYLES[variant], spacing = 60 + random() * 35;let selected = null;
    // 只尝试正常尺寸；沙地或图标间距不足时省略这棵树，不缩成迷你树。
    for (const baseScale of [.62]) {
      const scale = baseScale * .80 * (style.size || 1);
      const radius = style.radius * scale, offsetX = random() * 13, offsetY = random() * 13;let best = null, candidates = 0;
      for (let y = 100 * scale + offsetY; y < H - TASKBAR - 55 * scale; y += 13) for (let x = radius + 5 + offsetX; x < W - radius - 5; x += 13) {
        const shore = sampleArr(FB.s, x, y);
        if (shore > -25 || shore < -58 || (window.__visible && !__visible(x, y, 60))) continue;
        if (chosen.some(q => Math.hypot(q.x - x, q.y - y) < spacing) || kept.some(q => Math.hypot(q.x - x, q.y - y) < spacing)) continue;
        // 弯干款以根部为轴翻转，弯曲方向跟随岸线朝向海水；不旋转树的竖直视角。
        const seaX = style.faceSea ? sampleArr(FB.s, x + 8, y) - sampleArr(FB.s, x - 8, y) : 0;
        const mirror = style.faceSea && seaX * style.crown[0] < 0 ? -1 : 1;
        const crown = {x: x + style.crown[0] * scale * mirror, y: y + style.crown[1] * scale};
        if (crown.x < radius + 3 || crown.x > W - radius - 3) continue;
        // (a crown may tuck up to ~40% under a window: the palm stands by it, half behind it; a crown wholly clear of
        // every window found almost no room on the narrow sand round a big one, so most layouts got 0-1 palms)
        if (crown.y < radius + 3 || !beachPalmClear(x, y - 16 * scale, 10 * scale) || !beachPalmClear(crown.x, crown.y, radius * .2)) continue;
        // (and two crowns never merge into one)
        if (chosen.concat(kept).some(q => q.cx !== undefined && Math.hypot(q.cx - crown.x, q.cy - crown.y) < (q.r + radius) * .8)) continue;
        if (random() < 1 / ++candidates) best = {x, y, scale, variant, mirror, opacity: 0, retiring: false, cx: crown.x, cy: crown.y, r: radius};
      }
      if (best) {selected = best;break;}
    }
    if (selected) chosen.push(selected);
  }
  return chosen;
}

function drawMaldivesPalms(now, pass, configurePass, context) {
  if (!FB || !beachPalmImages.every(image => image.complete && image.naturalWidth)) return;
  if (!beachPalmsScene) beachPalmsScene = {atlas: makeMaldivesPalmAtlas(), palms: [], previous: now};
  const scene = beachPalmsScene, dt = Math.max(0, Math.min(.1, (now - scene.previous) / 1000));scene.previous = now;
  const count = Math.max(0, Math.min(10, Math.round((Number.isFinite(P.palms) ? P.palms : 4) * (window.Span ? Span.n : 1))));
  // While windows are moving (a new coast every frame of a drag) the palms stay where they stand, fading only where their
  // sand goes; they're placed again once the coast has stopped changing, not re-dealt each frame as ghosts
  const held = typeof iconsLive === 'boolean' ? iconsLive : typeof morphT0 === 'number' && performance.now() - morphT0 < 250;   // (the host says so; older hosts: by timing)
  const moving = held && scene.field && scene.seed === seed;
  // Tidewall: a new coast is dealt palms only once it has finished moving in (placed on the coming coast while the old
  // one still showed, new palms faded in standing in the sea); palms whose sand is still good sand stay where they are,
  // and only the missing ones are added (re-dealing the whole set cross-faded every palm to a new spot after each drag)
  const coastDone = typeof curMix !== 'number' || curMix >= 1;
  const layoutChanged = !moving && coastDone && (scene.field !== FB || scene.seed !== seed || scene.width !== W || scene.height !== H);
  if (layoutChanged || (!moving && coastDone && scene.count !== count)) {
    const reseeded = scene.seed !== seed || scene.width !== W || scene.height !== H;
    const standing = reseeded ? [] : scene.palms.filter(q => !q.retiring && beachPalmStillGood(q)).slice(0, count);
    for (const old of scene.palms) old.retiring = !standing.includes(old);
    const more = count - standing.length;
    if (more > 0) for (const p of chooseMaldivesPalms(standing, more)) scene.palms.push({...p, opacity: 0, retiring: false});
    scene.field = FB;scene.seed = seed;scene.width = W;scene.height = H;
    scene.count = count;
  }
  configurePass(now, pass, context);
  gl.activeTexture(gl.TEXTURE6);gl.bindTexture(gl.TEXTURE_2D, scene.atlas);gl.uniform1i(pass.U.uPalmAtlas, 6);
  gl.enable(gl.BLEND);gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
  for (const palm of scene.palms) {
    const onSand = Math.max(0, Math.min(1, -curS(palm.x, palm.y) / 4));
    const target = palm.retiring ? 0 : onSand;
    palm.opacity += (target - palm.opacity) * (1 - Math.exp(-dt * (target < palm.opacity ? 9 : 4)));   // (gone quickly once its sand has left: no palm standing in the sea)
    if (palm.opacity < .003) continue;
    gl.uniform4f(pass.U.uPalm, palm.x - (typeof OX !== 'undefined' ? OX : 0), palm.y - (typeof OY !== 'undefined' ? OY : 0), palm.scale, palm.variant);gl.uniform1f(pass.U.uPalmOpacity, palm.opacity);
    gl.uniform1f(pass.U.uPalmMirror, palm.mirror);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }
  scene.palms = scene.palms.filter(p => !p.retiring || p.opacity > .003);
  gl.disable(gl.BLEND);
}
