//-------------------------------------------------------------------------------------------------------------------------------------------------------------
HEADER
{
	DevShader = true;
	Description = "Screen space global illumination on its own, r_ssgi_debug";
}

//-------------------------------------------------------------------------------------------------------------------------------------------------------------
MODES
{
	Default();
	Forward();
}

//-------------------------------------------------------------------------------------------------------------------------------------------------------------
FEATURES
{
}

//-------------------------------------------------------------------------------------------------------------------------------------------------------------
COMMON
{
	#include "postprocess/shared.hlsl"
}

//-------------------------------------------------------------------------------------------------------------------------------------------------------------
struct VertexInput
{
	float3 vPositionOs : POSITION < Semantic( PosXyz ); >;
	float2 vTexCoord : TEXCOORD0 < Semantic( LowPrecisionUv ); >;
};

//-------------------------------------------------------------------------------------------------------------------------------------------------------------
struct PixelInput
{
	float2 vTexCoord : TEXCOORD0;

	#if ( PROGRAM == VFX_PROGRAM_VS )
		float4 vPositionPs : SV_Position;
	#endif

	#if ( PROGRAM == VFX_PROGRAM_PS )
		float4 vPositionSs : SV_Position;
	#endif
};

//-------------------------------------------------------------------------------------------------------------------------------------------------------------
VS
{
	PixelInput MainVs( VertexInput i )
	{
		PixelInput o;
		o.vPositionPs = float4( i.vPositionOs.xy, 0.0f, 1.0f );
		o.vTexCoord = i.vTexCoord;
		return o;
	}
}

//-------------------------------------------------------------------------------------------------------------------------------------------------------------
PS
{
	#include "postprocess/common.hlsl"

	Texture2D g_tGlobalIllumination < Attribute( "ScreenSpaceGI" ); SrgbRead( false ); >;

	float4 MainPs( PixelInput i ) : SV_Target0
	{
		// What the lighting pass adds, before the baked light fills in the rest
		return float4( g_tGlobalIllumination.SampleLevel( g_sBilinearClamp, i.vPositionSs.xy / g_vRenderTargetSize, 0 ).rgb, 1 );
	}
}
