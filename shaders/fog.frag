#version 440

// Drifting ground fog: three layers of value-noise fbm moving at different
// speeds and scales (parallax), the middle one domain-warped by the first so
// the wisps curl instead of sliding. Heavier toward the bottom of the screen,
// with a soft vignette in the background colour. Output is premultiplied.
//
// Compile with: qsb --glsl "100es,120,150" --hlsl 50 --msl 12 -o fog.frag.qsb fog.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float time;
    float density;
    float aspect;
    float vignette;
    vec4 fogColor;
    vec4 glowColor;
    vec4 shadeColor;
};

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    mat2 rotate = mat2(1.6, 1.2, -1.2, 1.6);
    for (int i = 0; i < 5; i++) {
        value += amplitude * noise(p);
        p = rotate * p;
        amplitude *= 0.5;
    }
    return value;
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 p = vec2(uv.x * aspect, uv.y);
    float t = time;

    float far = fbm(p * 0.9 + vec2(t * 0.010, -t * 0.002));
    float mid = fbm(p * 1.7 + vec2(t * 0.022, t * 0.004) + far * 0.8);
    float near = fbm(p * 3.1 + vec2(-t * 0.040, t * 0.006) + mid * 0.6);

    float mist = smoothstep(0.38, 0.82, far * 0.45 + mid * 0.45 + near * 0.30);
    float ground = mix(0.45, 1.0, smoothstep(0.05, 1.0, uv.y));
    float fogAlpha = clamp(mist * ground * density, 0.0, 1.0);
    vec3 fog = mix(fogColor.rgb, glowColor.rgb, clamp(near * 0.7 - 0.15, 0.0, 1.0));

    vec2 c = (uv - 0.5) * vec2(1.15, 1.0);
    float shadeAlpha = smoothstep(0.30, 0.95, length(c)) * vignette;

    vec4 fogLayer = vec4(fog * fogAlpha, fogAlpha);
    vec4 shadeLayer = vec4(shadeColor.rgb * shadeAlpha, shadeAlpha);
    fragColor = (fogLayer + shadeLayer * (1.0 - fogLayer.a)) * qt_Opacity;
}
