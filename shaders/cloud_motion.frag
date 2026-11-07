#include <flutter/runtime_effect.glsl>
uniform vec2 uAtlasSize;
uniform vec2 uFrameA;
uniform vec2 uFrameB;
uniform vec2 uFlowSize;
uniform vec2 uFlowOrigin;
uniform vec2 uTileSize;
uniform float uCell;
uniform float uRange;
uniform float uMix;
uniform sampler2D uArt;
uniform sampler2D uFlow;
out vec4 fragColor;

vec3 field(vec2 p,float back) {
  vec2 q=uFlowOrigin+vec2(back*uCell,0.)+vec2(.5)+clamp(p/uTileSize,vec2(0.),vec2(1.))*(uCell-1.);
  vec3 data=texture(uFlow,q/uFlowSize).rgb;
  return vec3((data.rg*255.-128.)/127.*uRange,data.b);
}
vec4 art(vec2 p,vec2 origin) {
  if(any(lessThan(p,vec2(0.)))||any(greaterThanEqual(p,uTileSize)))return vec4(0.);
  return texture(uArt,(origin+clamp(p,vec2(.5),uTileSize-vec2(.5)))/uAtlasSize);
}
void main() {
  vec2 p=FlutterFragCoord().xy;
  vec2 a=p-uMix*field(p,0.).xy;
  vec2 b=p-(1.-uMix)*field(p,1.).xy;
  a=p-uMix*field(a,0.).xy;
  b=p-(1.-uMix)*field(b,1.).xy;
  float wa=(1.-uMix)*max(.15,field(a,0.).z);
  float wb=uMix*max(.15,field(b,1.).z);
  // Warp both whole drawings into correspondence before combining their
  // premultiplied colors. No fixed head, clipped hand or dissolve-only frame.
  fragColor=(art(a,uFrameA)*wa+art(b,uFrameB)*wb)/max(.001,wa+wb);
}
