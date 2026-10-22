#include <flutter/runtime_effect.glsl>
precision highp float;
uniform vec2 uResolution;
uniform float uTime;
uniform float uEnergy;
uniform float uPixelRatio;
out vec4 fragColor;

// Original water-drop material, shared mathematically with original-orb.tsx.
float hashNoise(vec2 p) {
  return fract(sin(p.x * 117.17 + p.y * 311.93) * 43719.683);
}
float noise(vec2 p) {
  vec2 cell = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hashNoise(cell), hashNoise(cell + vec2(1.0, 0.0)), f.x),
             mix(hashNoise(cell + vec2(0.0, 1.0)), hashNoise(cell + 1.0), f.x), f.y);
}
float mist(vec2 p) {
  float sum = 0.0, weight = 0.56;
  for (int i = 0; i < 4; i++) {
    sum += weight * noise(p);
    p = mat2(0.8, -0.6, 0.6, 0.8) * p * 2.07 + vec2(3.1, 7.6);
    weight *= 0.49;
  }
  return sum;
}
float spot(vec2 p, vec2 center, vec2 stretch, float falloff) {
  vec2 q = (p - center) * stretch;
  return exp(-dot(q, q) * falloff);
}
void main() {
  // Flutter coordinates start at the top; the browser reference starts below.
  vec2 coord = FlutterFragCoord().xy;
  coord.y = uResolution.y - coord.y;
  vec2 p = (coord * 2.0 - uResolution) / min(uResolution.x, uResolution.y);
  float t = uTime, e = clamp(uEnergy, 0.0, 1.0);
  p.y *= 1.0 - e * 0.035;
  float r = length(p), angle = atan(p.y, p.x);
  float form = 0.79 + (0.009 + e * 0.06) * sin(angle * 3.0 - t * 0.65)
                    + e * 0.018 * sin(angle * 5.0 + t * 0.7);
  float aa = 2.4 / (min(uResolution.x, uResolution.y) * uPixelRatio);
  float mask = 1.0 - smoothstep(form - aa, form + aa, r);
  vec2 q = p / form;
  float z = sqrt(max(0.0, 1.0 - dot(q, q))), edge = pow(1.0 - z, 3.0);
  vec2 drift = vec2(sin(t * 0.21), cos(t * 0.17)) * 0.25;
  float cloud = mist(q * 2.05 + drift + vec2(t * 0.025, -t * 0.017));
  float soft = spot(q, vec2(-0.3, 0.42), vec2(0.86, 1.35), 3.5);
  float gleam = spot(q, vec2(-0.36, 0.45), vec2(0.7, 1.55), 21.0);
  float wash = 0.5 + 0.5 * sin(q.x * 2.2 + q.y + cloud * 1.2 + t * 0.25);
  vec3 color = mix(vec3(1.0, 0.8, 0.76), vec3(0.72, 0.75, 0.95), wash);
  color = mix(color, vec3(1.0, 0.94, 0.81), soft * 0.65);
  float refraction = exp(-pow((r / form - (0.68 + 0.035 * sin(angle * 2.0 + t * 0.2))) / 0.065, 2.0));
  color += refraction * vec3(0.07, 0.09, 0.12) + edge * vec3(0.06, 0.01, 0.03);
  color = mix(color, vec3(1.0), gleam * 0.83);
  float alpha = clamp(mask * (0.79 + edge * 0.17), 0.0, 1.0);
  // Flutter shaders require premultiplied alpha.
  fragColor = vec4(clamp(color, 0.0, 1.0) * alpha, alpha);
}
