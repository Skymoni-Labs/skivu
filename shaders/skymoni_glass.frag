// Optical equations adapted from Skymoni's GlassLensRenderer, MIT.
// Copyright (c) 2025-2026 pandadog. See licenses/SkymoniLiquidGlass-MIT.txt.
#include <flutter/runtime_effect.glsl>
uniform vec2 uTextureSize;
uniform vec2 uBoxSize;
uniform mat3 uLocalToScreen;
uniform mat3 uScreenToLocal;
uniform vec2 uSubpass;
uniform float uDpr;
uniform float uRadius;
uniform float uBevel;
uniform float uRefract;
uniform float uDark;
uniform float uGlassAlpha;
uniform float uTintAlpha;
uniform sampler2D uContent;
out vec4 fragColor;

float sdf(vec2 p) {
  vec2 q=abs(p-uBoxSize*.5)-uBoxSize*.5+uRadius;
  return length(max(q,vec2(0.)))+min(max(q.x,q.y),0.)-uRadius;
}
vec2 mapPoint(mat3 m,vec2 p) {vec3 v=m*vec3(p,1.);return v.xy/v.z;}
vec2 sampleUv(vec2 local) {
  vec2 coord=mapPoint(uLocalToScreen,local/uDpr)*uDpr-uSubpass;
  vec2 uv=clamp(coord,vec2(.5),uTextureSize-vec2(.5))/uTextureSize;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y=1.-uv.y;
#endif
  return uv;
}
void main() {
  vec2 p=mapPoint(uScreenToLocal,(FlutterFragCoord().xy+uSubpass)/uDpr)*uDpr;
  float d=sdf(p),cov=clamp(.5-d/1.5,0.,1.);
  if(cov<=.004){fragColor=vec4(0.);return;}
  vec2 n=vec2(sdf(p+vec2(1.,0.))-sdf(p-vec2(1.,0.)),sdf(p+vec2(0.,1.))-sdf(p-vec2(0.,1.)));
  n=length(n)>.0001?normalize(n):vec2(0.,-1.);
  float t=clamp(-d/max(uBevel,1.),0.,1.);
  float gB=pow(5.,-1.7);
  float slope=(pow(1.+4.*t,-1.7)-gB)/(1.-gB);
  vec2 offset=-n*slope*uRefract;
  vec3 col=vec3(texture(uContent,sampleUv(p+offset*(1.-.065*slope))).r,
    texture(uContent,sampleUv(p+offset)).g,
    texture(uContent,sampleUv(p+offset*(1.+.065*slope))).b);
  float lum=dot(col,vec3(.2126,.7152,.0722));
  float satNow=max(col.r,max(col.g,col.b))-min(col.r,min(col.g,col.b));
  float room=1.-smoothstep(.2,.85,satNow),hl=1.-smoothstep(.75,.98,lum);
  col=clamp(mix(vec3(lum),col,1.+.25*mix(.3,1.,room*hl)),vec3(0.),vec3(1.));
  col=mix(col,vec3(1.),uTintAlpha);
  vec3 glassTint=mix(vec3(1.),vec3(12.,26.,39.)/255.,uDark);
  float lumTint=dot(col,vec3(.2126,.7152,.0722));
  vec3 absorbed=col*mix(vec3(1.),glassTint,.85);
  vec3 scattered=glassTint*(.38*(1.-lumTint));
  col=mix(col,clamp(absorbed+scattered,vec3(0.),vec3(1.)),uGlassAlpha);
  float facing=dot(n,-vec2(.866,.5));
  float lf=pow(max(facing,0.),4.5),lb=pow(max(-facing,0.),4.5);
  float band=clamp(uBevel*.3,2.,6.);
  float glow=clamp((-d-1.)/2.,0.,1.)*pow(clamp(1.-(-d-3.)/band,0.,1.),1.5)*cov;
  float hair=clamp(1.-abs(d+1.)/2.,0.,1.)*cov;
  col+=vec3(hair*.70*(lf+lb)+glow*.10*lf);
  fragColor=vec4(clamp(col,vec3(0.),vec3(1.))*cov,cov);
}
