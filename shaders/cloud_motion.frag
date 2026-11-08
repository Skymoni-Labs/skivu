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
uniform vec2 uScale;
uniform vec2 uOffsetA;
uniform vec2 uOffsetB;
uniform float uSingleSource;
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
  float scale=mix(uScale.x,uScale.y,uMix);
  vec2 q=p-mix(uOffsetA,uOffsetB,uMix);
  vec2 a=q/scale;
  vec2 b=a;
  a=(q-uMix*uScale.y*field(a,0.).xy)/scale;
  b=(q-(1.-uMix)*uScale.x*field(b,1.).xy)/scale;
  a=(q-uMix*uScale.y*field(a,0.).xy)/scale;
  b=(q-(1.-uMix)*uScale.x*field(b,1.).xy)/scale;
  if (uSingleSource > .5) {
    // A hand belongs to one complete original drawing. Blending two drawings
    // at a wrist occlusion can expose both silhouettes as a third hand.
    fragColor=uMix<.5 ? art(a,uFrameA) : art(b,uFrameB);
    return;
  }
  float wa=(1.-uMix)*max(.15,field(a,0.).z);
  float wb=uMix*max(.15,field(b,1.).z);
  // Warp both whole drawings into correspondence before combining their
  // premultiplied colors. No fixed head, clipped hand or dissolve-only frame.
  fragColor=(art(a,uFrameA)*wa+art(b,uFrameB)*wb)/max(.001,wa+wb);
}
