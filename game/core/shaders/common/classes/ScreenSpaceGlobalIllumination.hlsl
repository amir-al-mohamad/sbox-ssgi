#ifndef SCREEN_SPACE_GLOBAL_ILLUMINATION_HLSL
#define SCREEN_SPACE_GLOBAL_ILLUMINATION_HLSL

//-------------------------------------------------------------------------------------------------------------------------------------------------------------
// Accessor for the result of screen space global illumination
//-------------------------------------------------------------------------------------------------------------------------------------------------------------

// The effect keeps its result in a texture of its own, so the index holds from frame to frame, and publishes it through
// the camera's attributes along with the viewport it traced. A pipeline texture slot would be the right home for it,
// next to AO and SSR, but those are native and there are two.
int    g_nScreenSpaceGI         < Attribute( "ScreenSpaceGIIndex" ); Default( 0 ); >;
float2 g_vScreenSpaceGIViewport < Attribute( "ScreenSpaceGIViewport" ); Default2( 0, 0 ); >;

struct ScreenSpaceGlobalIllumination
{
    static bool IsEnabled()
    {
        // Child views, captures and the skybox among them, can't read a result traced for another viewport
        if ( g_nScreenSpaceGI <= 0 || g_bDisableScreenSpaceEffects )
            return false;

        return all( abs( g_vScreenSpaceGIViewport - g_vViewportSize ) < 0.5 );
    }

    // The bounced light arriving at the pixel, cosine weighted, premultiplied by the share of its hemisphere the rays
    // got to see. Blend it over the indirect diffuse the pixel already has: rgb + ( 1 - a ) * indirect
    static float4 Sample( float2 ScreenPosition )
    {
        if ( !IsEnabled() )
            return 0;

        Texture2D tGI = Bindless::GetTexture2D( asDynamicUniform( UniformIndex( g_nScreenSpaceGI ) ) );
        return tGI.SampleLevel( g_sBilinearClamp, ScreenPosition * g_vInvViewportSize, 0 );
    }
};

#endif // SCREEN_SPACE_GLOBAL_ILLUMINATION_HLSL
