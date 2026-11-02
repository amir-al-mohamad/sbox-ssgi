//-------------------------------------------------------------------------------------------------------------------------------------------------------------
HEADER
{
	DevShader = true;
	Description = "Screen space global illumination";
}

//-------------------------------------------------------------------------------------------------------------------------------------------------------------
MODES
{
	Default();
}

//-------------------------------------------------------------------------------------------------------------------------------------------------------------
FEATURES
{
}

//-------------------------------------------------------------------------------------------------------------------------------------------------------------
COMMON
{
	#include "system.fxc" // This should always be the first include in COMMON
	#include "common.fxc"
	#include "math_general.fxc"
	#include "encoded_normals.fxc"

	#define PASS_TRACE 0
	#define PASS_RESOLVE 1
	#define PASS_ACCUMULATE 2
	#define PASS_FILTER 3
	#define PASS_UPSAMPLE 4

	DynamicCombo( D_PASS, 0..4, Sys( PC ) );
	DynamicCombo( D_QUALITY, 0..2, Sys( PC ) );
}

//-------------------------------------------------------------------------------------------------------------------------------------------------------------
CS
{
    #include "common/classes/Depth.hlsl"
    #include "common/classes/ScreenSpaceTrace.hlsl"
    #include "common/classes/Normals.hlsl"

    //-------------------------------------------------------------------------------------------------------------------
    //
    // Diffuse bounce from what's on screen, at half resolution. ReSTIR GI on top of the SSR trace. Five passes:
    //
    //  Trace       cosine rays through the depth chain, lit by last frame's color where they land. Every ray is a
    //              candidate for the pixel's reservoir, which keeps one of them with a weight that stands in for all of
    //              them, and carries over from last frame while the surface under the pixel is the same
    //  Resolve     merges a few neighbours' reservoirs into the pixel's own (pairwise MIS) and shades what's left
    //  Accumulate  exponential history, started over where the surface changed or the reservoirs' light did
    //  Filter      à-trous in three dilated steps, stopping where the surface changes. The first step is next
    //              frame's history
    //  Upsample    bilateral to full resolution, into the texture the lighting shader reads
    //
    // GI texel p stands for the full resolution pixel SurfacePixel( p ), like SSR's does. The output is the cosine
    // weighted light the rays brought back, premultiplied by the share of rays that hit anything; the lighting shader
    // keeps its baked indirect for the rest.
    //
    //-------------------------------------------------------------------------------------------------------------------

    int                     g_nPreviousFrameColor   < Attribute( "PreviousFrameColorIndex" ); >;
    Texture2D               g_tBlueNoise            < Attribute( "BlueNoise" ); >;
    int                     g_nFrame                < Attribute( "Frame" ); Default( 0 ); >;
    float                   g_flIntensity           < Attribute( "Intensity" ); Default( 1 ); >;

    // Reservoirs, last frame's in and this frame's out: where the sample is and its W, the light leaving it and the
    // candidate count M, its surface normal and the trace's confidence in it
    Texture2D<float4>       g_tReservoirHit         < Attribute( "ReservoirHit" ); >;
    Texture2D<float4>       g_tReservoirLight       < Attribute( "ReservoirLight" ); >;
    Texture2D<float4>       g_tReservoirNormal      < Attribute( "ReservoirNormal" ); >;
    RWTexture2D<float4>     g_outReservoirHit       < Attribute( "OutReservoirHit" ); >;
    RWTexture2D<float4>     g_outReservoirLight     < Attribute( "OutReservoirLight" ); >;
    RWTexture2D<float4>     g_outReservoirNormal    < Attribute( "OutReservoirNormal" ); >;

    // What the trace learned about a pixel this frame: how much its sample's light changed, the share of rays that hit
    Texture2D<float2>       g_tTraceInfo            < Attribute( "TraceInfo" ); >;
    RWTexture2D<float2>     g_outTraceInfo          < Attribute( "OutTraceInfo" ); >;

    // What's accumulated at a pixel: rays, linear depth and normal they were accumulated for. Last frame's and this one's
    Texture2D<float4>       g_tSamples              < Attribute( "Samples" ); >;
    RWTexture2D<float4>     g_outSamples            < Attribute( "OutSamples" ); >;

    // Light in and out, whatever the pass before left: resolved, accumulated, filtered
    Texture2D<float4>       g_tLight                < Attribute( "Light" ); >;
    Texture2D<float4>       g_tHistory              < Attribute( "History" ); >;
    RWTexture2D<float4>     g_outLight              < Attribute( "OutLight" ); >;

    int                     g_nFilterStep           < Attribute( "FilterStep" ); Default( 1 ); >;
    bool                    g_bFilterLast           < Attribute( "FilterLast" ); Default( 0 ); >;

    SamplerState            BilinearClamp           < Filter( BILINEAR ); AddressU( CLAMP ); AddressV( CLAMP ); >;

    //-------------------------------------------------------------------------------------------------------------------

    // Rays a settled pixel traces a frame, neighbours the resolve merges, steps a ray gets
    #if ( D_QUALITY == 0 )
        static const int kRays = 1;
        static const int kNeighbours = 2;
        static const uint kSteps = 32;
    #elif ( D_QUALITY == 1 )
        static const int kRays = 2;
        static const int kNeighbours = 4;
        static const uint kSteps = 48;
    #else
        static const int kRays = 4;
        static const int kNeighbours = 6;
        static const uint kSteps = 64;
    #endif

    // A pixel with little history (just came into view) traces up to kFreshRays a frame until it has kFreshSamples
    static const int kFreshRays = 8;
    static const float kFreshSamples = 16;
    // Rays the accumulation holds at most, about 32 frames worth
    static const float kMaxSamples = 32 * kRays;
    // Candidates a reservoir carries over from last frame at most, so its sample can still move
    static const float kMaxReservoirM = 32;
    // Resolve reaches this far for neighbours, in GI texels
    static const float kResolveRadius = 16;
    // History is cut where the light of the reservoirs around a pixel changed by more than this since last frame.
    // Surfaces lit by this alone flicker by up to about a fifth, a light switched or recoloured changes several times over
    static const float kChangeFloor = 0.25;
    static const float kChangeScale = 4;
    // The filter reaches up to twice as far for pixels with fewer rays than this, so a short history doesn't boil
    static const float kSettledSamples = 32;

    //-------------------------------------------------------------------------------------------------------------------

    static const float kPi = 3.14159265;

    int2 GISize() { return ( int2( g_vViewportSize ) + 1 ) / 2; }

    // The full resolution pixel GI texel p stands for
    int2 SurfacePixel( int2 p ) { return min( p * 2 + 1, int2( g_vViewportSize ) - 1 ); }

    // Where a point at full resolution pixel position `pixel` falls among the GI texels, in texels with their centres at
    // +0.5 like a texture's: texel p stands for pixel 2p + 1, whose centre is at 2p + 1.5
    float2 TexelPosition( float2 pixel ) { return ( pixel - 0.5 ) * 0.5; }

    bool IsSky( int2 pixel ) { return Depth::GetNormalized( pixel ) <= 0; }

    // Overbright history is Inf in half float and turns NaN once anything multiplies it; keep everything finite
    float3 Finite( float3 c ) { return select( isnan( c ), 0, min( c, 65504.0 ) ); }
    float4 Finite( float4 c ) { return select( isnan( c ), 0, min( c, 65504.0 ) ); }

    // Light is accumulated and filtered compressed (Karis), so one bright hit, a lamp or a highlight on the floor, doesn't
    // outweigh its neighbours. Even light comes back as it was
    float3 Compress( float3 c ) { return c / ( 1 + Luminance( c ) ); }
    float3 Expand( float3 c ) { return c / max( 1 - Luminance( c ), 1e-3 ); }

    // Where a world position was on last frame's screen, in pixels, and its depth there. False when it wasn't on it, or
    // was behind the camera: ReprojectFromLastFrameSs divides through regardless and mirrors those onto the screen.
    // Anything within 32 units moves with the camera, a viewmodel, and is where it is now; the rule Motion::Get goes by
    bool LastFramePixel( float3 positionWs, out float3 pixel )
    {
        float3 positionVs = Position4WsToVs( float4( positionWs, 1 ) ).xyz;
        float4 clip = mul( g_matCurrFrameViewToPrevFrameProj, float4( positionVs, 1 ) );
        if ( dot( positionWs - g_vCameraPositionWs, g_vCameraDirWs ) <= 32 )
        {
            // Clip space this time, the reprojection above lands in pixels
            clip = Position4WsToPs( float4( positionWs, 1 ) );
            clip.xy = ( clip.xy * float2( 0.5, -0.5 ) + 0.5 * clip.w ) * g_vViewportSize;
        }

        pixel = clip.xyz / clip.w;
        return clip.w > 0 && all( pixel.xy >= 0 ) && all( pixel.xy < g_vViewportSize );
    }

    //-------------------------------------------------------------------------------------------------------------------
    // Random numbers
    //-------------------------------------------------------------------------------------------------------------------

    uint Hash( uint x )
    {
        x ^= x >> 16;
        x *= 0x7feb352du;
        x ^= x >> 15;
        x *= 0x846ca68bu;
        x ^= x >> 16;
        return x;
    }

    uint Seed( int2 p, uint salt ) { return Hash( uint( p.x ) | ( uint( p.y ) << 16 ) ) ^ Hash( uint( g_nFrame ) * 4 + salt ); }

    float Random( inout uint seed )
    {
        seed = Hash( seed );
        return ( seed >> 8 ) * ( 1.0 / 16777216.0 );
    }

    // R2 sequence: every next point lands in the emptiest part of the square
    float2 R2( int n ) { return frac( float2( 0.7548776662, 0.5698402910 ) * n ); }

    float3 CosineDirection( float2 xi, float3 n )
    {
        float phi = 2 * kPi * xi.x;
        float r = sqrt( xi.y );
        float3 local = float3( r * cos( phi ), r * sin( phi ), sqrt( saturate( 1 - xi.y ) ) );
        float3 up = abs( n.z ) < 0.999 ? float3( 0, 0, 1 ) : float3( 1, 0, 0 );
        float3 t = normalize( cross( up, n ) );
        float3 b = cross( n, t );
        return normalize( local.x * t + local.y * b + local.z * n );
    }

    //-------------------------------------------------------------------------------------------------------------------
    // History: is the thing under a GI texel the thing that was there last frame, and how much has it accumulated
    //-------------------------------------------------------------------------------------------------------------------

    // Rays accumulated where this pixel's point was last frame, 0 when something else was there: the depth and normal
    // on record have to match, or a car that drove past would keep shading the road. The best of the four texels around
    // the reprojected point counts, and which one it was: at an edge the nearest is often the thing next door, and a
    // pixel that started over every frame would never settle. Trace and Accumulate both ask, so they agree on the count
    float AccumulatedSamples( float3 positionWs, float3 normal, out float3 lastPixel, out int2 texel )
    {
        texel = 0;
        if ( g_nFrame == 0 || !LastFramePixel( positionWs, lastPixel ) )
            return 0;

        float expected = Depth::Linearize( lastPixel.z, lastPixel.xy );
        int2 corner = int2( floor( TexelPosition( lastPixel.xy ) - 0.5 ) );
        float samples = 0;

        [unroll]
        for ( int y = 0; y <= 1; y++ )
        {
            [unroll]
            for ( int x = 0; x <= 1; x++ )
            {
                int2 q = clamp( corner + int2( x, y ), 0, GISize() - 1 );
                float4 had = g_tSamples[q];
                if ( !all( isfinite( had ) ) || had.x <= samples )
                    continue;
                if ( abs( had.y - expected ) > expected * 0.05 + 1 || dot( DecodeNormal2D( had.zw ), normal ) < 0.8 )
                    continue;

                samples = had.x;
                texel = q;
            }
        }

        return samples;
    }

    int RaysFor( float samples ) { return clamp( int( kFreshSamples - samples ), kRays, kFreshRays ); }

    //-------------------------------------------------------------------------------------------------------------------
    // Reservoirs
    //-------------------------------------------------------------------------------------------------------------------

    // One sample out of all the candidates a pixel has seen, picked in proportion to how much each would bring it, with
    // the weight W that lets the one sample stand in for the lot. Reused over frames and between neighbours a pixel draws
    // on far more rays than it traces, and a rare bright hit, a lamp or a lit window, stays found rather than flickering
    // in and out with whichever rays happen to find it
    struct Reservoir
    {
        float3 positionWs;
        float3 normal;
        float3 color;
        float confidence;
        float weightSum;
        float M;
        float W;
    };

    // What a sample brings the point at positionWs: the luminance of its light times the cosine
    float Target( Reservoir r, float3 positionWs, float3 normal )
    {
        return Luminance( r.color * r.confidence ) * saturate( dot( normal, normalize( r.positionWs - positionWs ) ) );
    }

    // Stream a sample standing in for m candidates, with its resampling weight, into r
    void Merge( inout Reservoir r, Reservoir s, float weight, float m, inout uint seed )
    {
        r.weightSum += weight;
        r.M += m;
        if ( weight <= 0 || Random( seed ) * r.weightSum >= weight )
            return;

        r.positionWs = s.positionWs;
        r.normal = s.normal;
        r.color = s.color;
        r.confidence = s.confidence;
    }

    Reservoir LoadReservoir( int2 p )
    {
        float4 hit = g_tReservoirHit[p];
        float4 light = g_tReservoirLight[p];
        float4 normal = g_tReservoirNormal[p];

        Reservoir r = (Reservoir)0;
        if ( !all( isfinite( hit ) ) || !all( isfinite( light ) ) || !all( isfinite( normal ) ) || light.a <= 0 )
            return r;

        r.positionWs = hit.xyz;
        r.W = hit.w;
        r.color = light.rgb;
        r.M = light.a;
        r.normal = DecodeNormal2D( normal.xy );
        r.confidence = normal.z;
        return r;
    }

    void StoreReservoir( int2 p, Reservoir r )
    {
        g_outReservoirHit[p] = float4( r.positionWs, r.W );
        g_outReservoirLight[p] = float4( r.color, r.M );
        g_outReservoirNormal[p] = float4( EncodeNormal2D( r.normal ), r.confidence, 0 );
    }

    // The light the sample brings the point: an estimate of the cosine weighted light from every direction, with misses
    // bringing nothing, the same thing the rays' plain average estimates
    float3 Shade( Reservoir r, float3 positionWs, float3 normal )
    {
        float cosine = saturate( dot( normal, normalize( r.positionWs - positionWs ) ) );
        return r.color * r.confidence * cosine / kPi * r.W;
    }

    // The solid angle a sample at y with normal ny takes up seen from `to`, over what it takes up seen from `from`: how a
    // direction's density changes when the point it's seen from moves and the sample stays. 0 when y faces away from either
    float ShiftJacobian( float3 y, float3 ny, float3 from, float3 to )
    {
        float3 toFrom = from - y;
        float3 toTo = to - y;
        float distanceFrom = dot( toFrom, toFrom );
        float distanceTo = dot( toTo, toTo );
        float cosFrom = dot( ny, toFrom ) * rsqrt( max( distanceFrom, 1e-8 ) );
        float cosTo = dot( ny, toTo ) * rsqrt( max( distanceTo, 1e-8 ) );
        if ( cosFrom <= 0 || cosTo <= 0 )
            return 0;

        return cosTo / cosFrom * distanceFrom / max( distanceTo, 1e-8 );
    }

    //-------------------------------------------------------------------------------------------------------------------
    // Trace
    //-------------------------------------------------------------------------------------------------------------------

    // Traces ray k of `rays` from the point and streams it into the reservoir. A miss is a candidate too, bringing
    // nothing. The resampling weight of a hit is its target over the ray's pdf; for cosine rays shot from the point the
    // cosines cancel and pi times the luminance is left
    bool TraceRay( int k, int rays, float2 offset, float3 positionWs, float3 normal, Texture2D color, inout Reservoir reservoir, inout uint seed )
    {
        float2 xi = frac( offset + float2( k / float( rays ), k * 0.6180339887 ) );
        float3 direction = CosineDirection( xi, normal );

        Reservoir candidate = (Reservoir)0;
        float weight = 0;

        TraceResult trace = ScreenSpace::Trace( positionWs, direction, kSteps );
        [branch]
        if ( trace.Confidence > 0 )
        {
            int2 hitPixel = int2( trace.HitUv * g_vViewportSize );
            float3 hitWs = Depth::GetWorldPosition( hitPixel + 0.5 );

            // The hit's light is last frame's color where it was then. Off that frame there's nothing to read yet, right
            // after a turn or at the edges, and that direction keeps its baked light rather than some other pixel's
            float3 lastPixel;
            if ( LastFramePixel( hitWs, lastPixel ) )
            {
                candidate.positionWs = hitWs;
                candidate.normal = normalize( Normals::Sample( hitPixel ) );
                candidate.color = Finite( color[int2( lastPixel.xy )].rgb );
                candidate.confidence = trace.Confidence;
                weight = kPi * Luminance( candidate.color * candidate.confidence );
            }
        }

        Merge( reservoir, candidate, weight, 1, seed );
        return weight > 0;
    }

    void Pass_Trace( int2 p )
    {
        int2 pixel = SurfacePixel( p );
        if ( IsSky( pixel ) )
        {
            StoreReservoir( p, (Reservoir)0 );
            g_outTraceInfo[p] = 0;
            return;
        }

        float3 positionWs = Depth::GetWorldPosition( pixel + 0.5 );
        float3 normal = normalize( Normals::Sample( pixel ) );

        float3 lastPixel;
        int2 historyTexel;
        float samples = AccumulatedSamples( positionWs, normal, lastPixel, historyTexel );
        int rays = RaysFor( samples );

        // Blue noise holds still on the screen, so neighbours get different directions, and shifts along R2 from frame to
        // frame; within a frame the rays spread as a lattice over the hemisphere, however many there are
        float2 offset = g_tBlueNoise[p % 256].rg + R2( g_nFrame & 1023 );
        Texture2D color = Bindless::GetTexture2D( g_nPreviousFrameColor );

        Reservoir reservoir = (Reservoir)0;
        uint seed = Seed( p, 0 );
        float hits = 0;

        // Every pixel's rays unrolled, the extra ones of fresh pixels in a loop the rest skip
        [unroll]
        for ( int k = 0; k < kRays; k++ )
            hits += TraceRay( k, rays, offset, positionWs, normal, color, reservoir, seed );
        [loop]
        for ( int extra = kRays; extra < rays; extra++ )
            hits += TraceRay( extra, rays, offset, positionWs, normal, color, reservoir, seed );

        // Last frame's reservoir where this point was then, if it's the same surface. Its sample's light is read again
        // where the sample was, so a light that changed doesn't linger; how much it changed is the accumulation's cue.
        // The read takes the closest colour among the pixels around: a thin emitter lands a pixel off under motion, and
        // the wall next to it is not a light that changed
        float change = 0;
        if ( samples > 0 )
        {
            Reservoir last = LoadReservoir( historyTexel );
            float3 samplePixel;
            if ( last.W > 0 && LastFramePixel( last.positionWs, samplePixel ) )
            {
                float3 now = last.color;
                float closest = 1e30;
                [unroll]
                for ( int y = -1; y <= 1; y++ )
                {
                    [unroll]
                    for ( int x = -1; x <= 1; x++ )
                    {
                        float3 near = Finite( color[clamp( int2( samplePixel.xy ) + int2( x, y ), 0, int2( g_vViewportSize ) - 1 )].rgb );
                        float distance = length( near - last.color );
                        if ( distance < closest )
                        {
                            closest = distance;
                            now = near;
                        }
                    }
                }
                change = closest / max( max( length( now ), length( last.color ) ), 1e-4 );
                last.color = now;
            }

            float m = min( last.M, kMaxReservoirM );
            Merge( reservoir, last, Target( last, positionWs, normal ) * last.W * m, m, seed );
        }

        float target = Target( reservoir, positionWs, normal );
        reservoir.W = target > 0 ? reservoir.weightSum / ( reservoir.M * target ) : 0;

        StoreReservoir( p, reservoir );
        g_outTraceInfo[p] = float2( change, hits / rays );
    }

    //-------------------------------------------------------------------------------------------------------------------
    // Resolve
    //-------------------------------------------------------------------------------------------------------------------

    // A few neighbours' reservoirs merged into the pixel's and the result shaded. Each sample gets a pairwise MIS weight,
    // the GRIS paper's: the pixel's own against every neighbour, how likely that neighbour would have come up with it; a
    // neighbour's, shifted here with the Jacobian, against the pixel. They sum to one, so W is the weight sum over the
    // target with no candidate count to divide by, nothing is counted twice, and a sample the pixel sees under a very
    // different solid angle than its owner does barely weighs. Visibility between the pixel and a neighbour's sample isn't
    // checked
    void Pass_Resolve( int2 p )
    {
        int2 pixel = SurfacePixel( p );
        if ( IsSky( pixel ) )
        {
            g_outLight[p] = 0;
            return;
        }

        float3 positionWs = Depth::GetWorldPosition( pixel + 0.5 );
        float3 normal = normalize( Normals::Sample( pixel ) );
        float depth = Depth::GetLinear( pixel + 0.5 );
        uint seed = Seed( p, 1 );

        Reservoir neighbours[kNeighbours];
        float3 neighbourPositions[kNeighbours];
        float3 neighbourNormals[kNeighbours];
        int count = 0;

        // The share of rays that hit, averaged over the same neighbours: the pixel's own is a couple of rays' worth
        float2 info = g_tTraceInfo[p];
        float hits = info.y;
        float hitPixels = 1;

        [unroll]
        for ( int i = 0; i < kNeighbours; i++ )
        {
            float radius = kResolveRadius * sqrt( Random( seed ) );
            float angle = 2 * kPi * Random( seed );
            int2 q = clamp( p + int2( round( float2( cos( angle ), sin( angle ) ) * radius ) ), 0, GISize() - 1 );
            int2 qPixel = SurfacePixel( q );
            if ( all( q == p ) || IsSky( qPixel ) )
                continue;

            float3 qNormal = normalize( Normals::Sample( qPixel ) );
            if ( abs( Depth::GetLinear( qPixel + 0.5 ) - depth ) > depth * 0.1 || dot( qNormal, normal ) < 0.9 )
                continue;

            hits += g_tTraceInfo[q].y;
            hitPixels += 1;
            neighbours[count] = LoadReservoir( q );
            neighbourPositions[count] = Depth::GetWorldPosition( qPixel + 0.5 );
            neighbourNormals[count] = qNormal;
            count++;
        }

        Reservoir own = LoadReservoir( p );
        Reservoir reservoir = (Reservoir)0;

        // The pixel's own sample. In each pair its confidence is split over the neighbours
        float ownTarget = Target( own, positionWs, normal );
        float ownShare = count > 0 ? own.M / count * ownTarget : 0;
        float ownWeight = count > 0 ? 0 : 1;
        for ( int j = 0; j < count; j++ )
        {
            float theirs = Target( own, neighbourPositions[j], neighbourNormals[j] ) * ShiftJacobian( own.positionWs, own.normal, positionWs, neighbourPositions[j] );
            float total = ownShare + neighbours[j].M * theirs;
            ownWeight += total > 0 ? ownShare / total / count : 0;
        }
        Merge( reservoir, own, ownWeight * ownTarget * own.W, 0, seed );

        // The neighbours' samples, shifted here
        for ( int n = 0; n < count; n++ )
        {
            Reservoir neighbour = neighbours[n];
            if ( neighbour.W <= 0 )
                continue;

            float jacobian = ShiftJacobian( neighbour.positionWs, neighbour.normal, neighbourPositions[n], positionWs );
            float target = Target( neighbour, positionWs, normal );
            if ( jacobian <= 0 || target <= 0 )
                continue;

            float theirs = neighbour.M * Target( neighbour, neighbourPositions[n], neighbourNormals[n] ) / jacobian;
            float weight = theirs / ( theirs + own.M / count * target ) / count;
            Merge( reservoir, neighbour, weight * target * neighbour.W * jacobian, 0, seed );
        }

        float target = Target( reservoir, positionWs, normal );
        reservoir.W = target > 0 ? reservoir.weightSum / target : 0;

        float3 light = Finite( Shade( reservoir, positionWs, normal ) );
        g_outLight[p] = float4( Compress( light ), hits / hitPixels );
    }

    //-------------------------------------------------------------------------------------------------------------------
    // Accumulate
    //-------------------------------------------------------------------------------------------------------------------

    void Pass_Accumulate( int2 p )
    {
        int2 pixel = SurfacePixel( p );
        if ( IsSky( pixel ) )
        {
            g_outLight[p] = 0;
            g_outSamples[p] = 0;
            return;
        }

        float3 positionWs = Depth::GetWorldPosition( pixel + 0.5 );
        float3 normal = normalize( Normals::Sample( pixel ) );
        float depth = Depth::GetLinear( pixel + 0.5 );
        float4 current = Finite( g_tLight[p] );

        float3 lastPixel;
        int2 historyTexel;
        float samples = AccumulatedSamples( positionWs, normal, lastPixel, historyTexel );
        float rays = RaysFor( samples );

        // Where the reservoirs' light changed since last frame the history is cut short, so a light switched on shows in
        // a frame or two instead of fading in over the whole window
        float changed = 0;
        [unroll]
        for ( int y = -1; y <= 1; y++ )
        {
            [unroll]
            for ( int x = -1; x <= 1; x++ )
            {
                float change = g_tTraceInfo[clamp( p + int2( x, y ), 0, GISize() - 1 )].x;
                changed = max( changed, isfinite( change ) ? change : 0 );
            }
        }
        samples *= 1 - saturate( ( changed - kChangeFloor ) * kChangeScale );

        float4 accumulated = current;
        if ( samples > 0 )
        {
            float4 history = Finite( g_tHistory.SampleLevel( BilinearClamp, TexelPosition( lastPixel.xy ) / GISize(), 0 ) );

            // Clamped to the spread of the new light around the pixel, so what moved doesn't trail for long
            float4 sum = 0, squares = 0;
            [unroll]
            for ( int y = -1; y <= 1; y++ )
            {
                [unroll]
                for ( int x = -1; x <= 1; x++ )
                {
                    float4 near = Finite( g_tLight[clamp( p + int2( x, y ), 0, GISize() - 1 )] );
                    sum += near;
                    squares += near * near;
                }
            }
            float4 mean = sum / 9;
            float4 deviation = sqrt( max( squares / 9 - mean * mean, 0 ) );
            // The window never closes tighter than half the history itself: a frame with few hits can't drag a settled
            // texel down and back up, while something that really moved still fades out within a few frames
            float4 window = max( deviation * 2.5, abs( history ) * 0.5 );
            history = clamp( history, mean - window, mean + window );

            // Each frame weighs the rays it traced
            float total = min( samples + rays, kMaxSamples );
            accumulated = lerp( history, current, rays / total );
            samples = total;
        }
        else
        {
            samples = rays;
        }

        g_outLight[p] = accumulated;
        g_outSamples[p] = float4( samples, depth, EncodeNormal2D( normal ) );
    }

    //-------------------------------------------------------------------------------------------------------------------
    // Filter
    //-------------------------------------------------------------------------------------------------------------------

    // How much the surface at pixel q is the one at positionWs with normal: each lies in the other's tangent plane within
    // tolerance units, and they face the same way. A curved surface passes, a different surface behind or beside doesn't
    float SameSurface( float3 positionWs, float3 normal, int2 qPixel, float tolerance )
    {
        float3 qPosition = Depth::GetWorldPosition( qPixel + 0.5 );
        float3 qNormal = normalize( Normals::Sample( qPixel ) );
        float plane = max( abs( dot( qPosition - positionWs, normal ) ), abs( dot( positionWs - qPosition, qNormal ) ) );
        return exp( -plane / tolerance ) * pow( saturate( dot( normal, qNormal ) ), 2 );
    }

    // One à-trous step: a 5x5 B3 spline kernel with its taps g_nFilterStep texels apart, stopping on normal and depth so
    // light doesn't cross edges. Further apart for pixels with little history, closing in as they settle
    void Pass_Filter( int2 p )
    {
        int2 pixel = SurfacePixel( p );
        if ( IsSky( pixel ) )
        {
            g_outLight[p] = 0;
            return;
        }

        float3 normal = normalize( Normals::Sample( pixel ) );
        float depth = Depth::GetLinear( pixel + 0.5 );
        float3 positionWs = Depth::GetWorldPosition( pixel + 0.5 );
        float reach = g_nFilterStep * ( 1 + saturate( 1 - g_tSamples[p].x / kSettledSamples ) );
        float tolerance = depth * 0.01 * reach + 0.5;

        static const float kernel[3] = { 3.0 / 8.0, 1.0 / 4.0, 1.0 / 16.0 };
        float4 sum = 0;
        float weights = 0;

        [unroll]
        for ( int y = -2; y <= 2; y++ )
        {
            [unroll]
            for ( int x = -2; x <= 2; x++ )
            {
                int2 q = clamp( p + int2( round( float2( x, y ) * reach ) ), 0, GISize() - 1 );
                int2 qPixel = SurfacePixel( q );
                float4 light = g_tLight[q];
                if ( !all( isfinite( light ) ) )
                    continue;

                float w = kernel[abs( x )] * kernel[abs( y )];
                w *= SameSurface( positionWs, normal, qPixel, tolerance );
                sum += light * w;
                weights += w;
            }
        }

        // A texel with no surface like it around, a railing or a shelf's edge a texel wide, would keep its own noisy
        // estimate through every step and twinkle. It takes whatever is around it instead: a little wrong, but steady
        [branch]
        if ( weights - kernel[0] * kernel[0] < 0.05 )
        {
            sum = 0;
            weights = 0;
            [unroll]
            for ( int y = -2; y <= 2; y++ )
            {
                [unroll]
                for ( int x = -2; x <= 2; x++ )
                {
                    int2 q = clamp( p + int2( round( float2( x, y ) * reach ) ), 0, GISize() - 1 );
                    float4 light = g_tLight[q];
                    if ( !all( isfinite( light ) ) )
                        continue;

                    float3 qPosition = Depth::GetWorldPosition( SurfacePixel( q ) + 0.5 );
                    float w = kernel[abs( x )] * kernel[abs( y )] * exp( -abs( dot( qPosition - positionWs, normal ) ) / ( tolerance * 4 ) );
                    sum += light * w;
                    weights += w;
                }
            }
        }

        float4 light = sum / max( weights, 1e-4 );
        // Intensity scales the light. Below one it fades the whole effect, so zero leaves the baked light as it was
        if ( g_bFilterLast )
            light = float4( Expand( light.rgb ) * g_flIntensity, light.a * saturate( g_flIntensity ) );

        g_outLight[p] = light;
    }

    //-------------------------------------------------------------------------------------------------------------------
    // Upsample
    //-------------------------------------------------------------------------------------------------------------------

    // Each full resolution pixel takes the four GI texels around it, weighed by how alike their depth and normal are, so
    // the light of whatever is next door doesn't bleed in and silhouettes don't get a halo. A thin edge with no texel
    // like it takes the closest in depth
    void Pass_Upsample( int2 pixel )
    {
        if ( IsSky( pixel ) )
        {
            g_outLight[pixel] = 0;
            return;
        }

        float depth = Depth::GetLinear( pixel + 0.5 );
        float3 positionWs = Depth::GetWorldPosition( pixel + 0.5 );
        float3 normal = normalize( Normals::Sample( pixel ) );
        float2 low = ( pixel - 1 ) * 0.5;
        int2 corner = int2( floor( low ) );
        float2 fraction = low - corner;

        float4 sum = 0;
        float weights = 0;
        float4 nearest = 0;
        float nearestDelta = 1e30;

        [unroll]
        for ( int y = 0; y <= 1; y++ )
        {
            [unroll]
            for ( int x = 0; x <= 1; x++ )
            {
                int2 q = clamp( corner + int2( x, y ), 0, GISize() - 1 );
                int2 qPixel = SurfacePixel( q );
                float4 light = g_tLight[q];
                if ( !all( isfinite( light ) ) )
                    continue;

                float delta = abs( Depth::GetLinear( qPixel + 0.5 ) - depth );
                float2 bilinear = lerp( 1 - fraction, fraction, float2( x, y ) );
                float w = bilinear.x * bilinear.y;
                w *= SameSurface( positionWs, normal, qPixel, depth * 0.01 + 0.5 );
                sum += light * w;
                weights += w;

                if ( delta < nearestDelta )
                {
                    nearestDelta = delta;
                    nearest = light;
                }
            }
        }

        g_outLight[pixel] = weights > 1e-4 ? sum / weights : nearest;
    }

    //-------------------------------------------------------------------------------------------------------------------

    [numthreads( 8, 8, 1 )]
    void MainCs( uint2 id : SV_DispatchThreadID )
    {
        int2 p = int2( id );

        #if ( D_PASS == PASS_UPSAMPLE )
            if ( all( p < int2( g_vViewportSize ) ) )
                Pass_Upsample( p );
            return;
        #endif

        if ( any( p >= GISize() ) )
            return;

        #if ( D_PASS == PASS_TRACE )
            Pass_Trace( p );
        #elif ( D_PASS == PASS_RESOLVE )
            Pass_Resolve( p );
        #elif ( D_PASS == PASS_ACCUMULATE )
            Pass_Accumulate( p );
        #else
            Pass_Filter( p );
        #endif
    }
}
