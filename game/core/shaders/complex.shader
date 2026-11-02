//-------------------------------------------------------------------------------------------------------------------------------------------------------------
// An open reconstruction of complex, whose source is not public, so that the lighting changes in the shared code (such as
// screen-space global illumination) reach the materials drawn with it. Same features, parameters and feature rules as the
// shipped complex, built on the shared vr_shared_standard_* code, so maps and models render with it unchanged; checked
// against the shipped one pixel by pixel (the difference: no fog on the 3D skybox). Not done is what lives in the closed
// code and nothing here used: parallax, the second UV set, diffuse wrap. Those features are declared so materials using
// them load, but they change nothing.
//
// For testing only, until the shipped complex gets the same lighting changes: it replaces complex.shader_c when shaders
// are built from this branch.
//-------------------------------------------------------------------------------------------------------------------------------------------------------------
HEADER
{
	Description = "Complex (open reconstruction)";
	DevShader = true;
	Version = 1;
}

MODES
{
	Forward();
	Depth( S_MODE_DEPTH );
	ToolsShadingComplexity( "tools_shading_complexity.shader" );
}

FEATURES
{
	#include "vr_shared_standard_features.fxc"

	Feature( F_ANISOTROPIC_GLOSS, 0..1, "PBR" );
	Feature( F_RETRO_REFLECTIVE, 0..1, "PBR" );
	Feature( F_SCALE_NORMAL_MAP, 0..1, "Normal" );
	Feature( F_ENABLE_NORMAL_SELF_SHADOW, 0..1, "Normal" );
	Feature( F_USE_BENT_NORMALS, 0..1, "Normal" );
	Feature( F_SELF_ILLUM, 0..1, "PBR" );
	Feature( F_DETAIL_TEXTURE, 0..4( 0 = "None", 1 = "Mod2X", 2 = "Overlay", 3 = "Normals", 4 = "Overlay and Normals" ), "Detail Texture" );
	Feature( F_METALNESS_TEXTURE, 0..1, "PBR" );
	Feature( F_SECONDARY_UV, 0..1, "Secondary UV" );
	Feature( F_DIFFUSE_WRAP, 0..1, "PBR" );
	Feature( F_TRANSMISSIVE_BACKFACE_NDOTL, 0..1, "PBR" );
	Feature( F_CLOTH_SHADING, 0..1, "PBR" );
	Feature( F_PARALLAX_OCCLUSION, 0..1, "Rendering" );

	// feature rules: the same as the shipped complex (texts from its compiled file); materials made for it follow them,
	// and there are several times fewer combos to build
	FeatureRule( Allow1( F_ANISOTROPIC_GLOSS, F_ADDITIVE_BLEND ), "Anisotropic Gloss and Additive Blend are incompatible" );
	FeatureRule( Allow1( F_RETRO_REFLECTIVE, F_ANISOTROPIC_GLOSS ), "Retro Reflective and Anisotropic Gloss are not compatible" );
	FeatureRule( Allow1( F_RETRO_REFLECTIVE, F_ALPHA_TEST ), "Retro Reflective and Alpha Test are not compatible" );
	FeatureRule( Allow1( F_RETRO_REFLECTIVE, F_TRANSLUCENT ), "Retro Reflective and Translucent are not compatible" );
	FeatureRule( Allow1( F_RETRO_REFLECTIVE, F_TINT_MASK ), "Retro Reflective and Tint Mask are not compatible" );
	FeatureRule( Allow1( F_RETRO_REFLECTIVE, F_ADDITIVE_BLEND ), "Retro Reflective and Additive Blend are incompatible" );
	FeatureRule( Allow1( F_SCALE_NORMAL_MAP, F_ALPHA_TEST ), "Scale normals and Alpha Test are not compatible" );
	FeatureRule( Allow1( F_SCALE_NORMAL_MAP, F_TRANSLUCENT ), "Scale normals and Translucent are not compatible" );
	FeatureRule( Allow1( F_SCALE_NORMAL_MAP, F_ANISOTROPIC_GLOSS ), "Scale normals and Anisotropic Gloss are not compatible" );
	FeatureRule( Allow1( F_RETRO_REFLECTIVE, F_SCALE_NORMAL_MAP ), "Retro Reflective and Scale normals are not compatible" );
	FeatureRule( Allow1( F_SCALE_NORMAL_MAP, F_ADDITIVE_BLEND ), "Scale Normal Map and Additive Blend are incompatible" );
	FeatureRule( Allow1( F_ENABLE_NORMAL_SELF_SHADOW, F_ADDITIVE_BLEND ), "Enable Normal Self Shadow and Additive Blend are incompatible" );
	FeatureRule( Allow1( F_USE_BENT_NORMALS, F_ALPHA_TEST ), "Bent Normals and Alpha Test are not compatible" );
	FeatureRule( Allow1( F_USE_BENT_NORMALS, F_TINT_MASK ), "Bent Normals and Tint Mask are not compatible" );
	FeatureRule( Allow1( F_USE_BENT_NORMALS, F_RETRO_REFLECTIVE ), "Bent Normals and Retro Reflective are not compatible" );
	FeatureRule( Allow1( F_USE_BENT_NORMALS, F_ADDITIVE_BLEND ), "Use Bent Normals and Additive Blend are incompatible" );
	FeatureRule( Allow1( F_USE_BENT_NORMALS, F_SCALE_NORMAL_MAP ), "Use Bent Normals and Scaled Normal Maps are Incompatible" );
	FeatureRule( Allow1( F_SELF_ILLUM, F_RETRO_REFLECTIVE ), "Self Illum and Retro Reflective are not compatible" );
	FeatureRule( Allow1( F_DETAIL_TEXTURE, F_SELF_ILLUM ), "Detail Texture and Self Illum are not compatible" );
	FeatureRule( Allow1( F_DETAIL_TEXTURE, F_ANISOTROPIC_GLOSS ), "Detail Texture and Anisotropic Gloss are not compatible" );
	FeatureRule( Allow1( F_DETAIL_TEXTURE, F_RETRO_REFLECTIVE ), "Detail Texture and Retro Reflective are not compatible" );
	FeatureRule( Allow1( F_DETAIL_TEXTURE, F_ADDITIVE_BLEND ), "Detail Texture and Additive Blend are not compatible" );
	FeatureRule( Allow1( F_METALNESS_TEXTURE, F_ADDITIVE_BLEND ), "Metalness Texture and Additive Blend are not compatible" );
	FeatureRule( Allow1( F_SECONDARY_UV, F_RETRO_REFLECTIVE ), "Secondary UV and Retro Reflective are not compatible" );
	FeatureRule( Allow1( F_SECONDARY_UV, F_ENABLE_NORMAL_SELF_SHADOW ), "Secondary UV and Normal Self Shadow are not compatible" );
	FeatureRule( Allow1( F_SECONDARY_UV, F_USE_BENT_NORMALS ), "Secondary UV and Use Bent Normals are not compatible" );
	FeatureRule( Allow1( F_SECONDARY_UV, F_SCALE_NORMAL_MAP ), "Secondary UV and Scale normals are not compatible" );
	FeatureRule( Allow1( F_DIFFUSE_WRAP, F_RETRO_REFLECTIVE ), "Diffuse wrap and Retro Reflective are not compatible" );
	FeatureRule( Allow1( F_DIFFUSE_WRAP, F_SCALE_NORMAL_MAP ), "Diffuse wrap and Scale Normal Map are not compatible" );
	FeatureRule( Allow1( F_DIFFUSE_WRAP, F_DETAIL_TEXTURE ), "Diffuse wrap and Detail Texture are not compatible" );
	FeatureRule( Allow1( F_DIFFUSE_WRAP, F_ADDITIVE_BLEND ), "Diffuse wrap and Additive Blend are not compatible" );
	FeatureRule( Allow1( F_TRANSMISSIVE_BACKFACE_NDOTL, F_RETRO_REFLECTIVE ), "Transmissive Backface Ndotl and Retro Reflective are not compatible" );
	FeatureRule( Allow1( F_TRANSMISSIVE_BACKFACE_NDOTL, F_SCALE_NORMAL_MAP ), "Transmissive Backface Ndotl and Scale Normal Map are not compatible" );
	FeatureRule( Allow1( F_TRANSMISSIVE_BACKFACE_NDOTL, F_DETAIL_TEXTURE ), "Transmissive Backface Ndotl and Detail Texture are not compatible" );
	FeatureRule( Allow1( F_TRANSMISSIVE_BACKFACE_NDOTL, F_ADDITIVE_BLEND ), "Transmissive Backface Ndotl and Additive Blend are not compatible" );
	FeatureRule( Allow1( F_CLOTH_SHADING, F_ANISOTROPIC_GLOSS ), "Cloth Shading and Anisotropic Gloss are not compatible" );
	FeatureRule( Allow1( F_CLOTH_SHADING, F_RETRO_REFLECTIVE ), "Cloth Shading and Retro Reflective are not compatible" );
	FeatureRule( Allow1( F_CLOTH_SHADING, F_METALNESS_TEXTURE ), "Cloth Shading and Metalness Texture are not compatible" );
	FeatureRule( Allow1( F_CLOTH_SHADING, F_SCALE_NORMAL_MAP ), "Cloth Shading and Scale Normal Map are not compatible" );
	FeatureRule( Allow1( F_CLOTH_SHADING, F_DIFFUSE_WRAP ), "Cloth Shading and Diffuse Wrap are not compatible" );
	FeatureRule( Allow1( F_PARALLAX_OCCLUSION, F_TRANSLUCENT ), "Parallax Occlusion and Translucent are not compatible" );
	FeatureRule( Allow1( F_PARALLAX_OCCLUSION, F_ALPHA_TEST ), "Parallax Occlusion and Alpha Test are not compatible" );
	FeatureRule( Allow1( F_PARALLAX_OCCLUSION, F_CLOTH_SHADING ), "Parallax Occlusion and Cloth Shading are not compatible" );
	FeatureRule( Allow1( F_PARALLAX_OCCLUSION, F_USE_BENT_NORMALS ), "Parallax Occlusion and Bent Normals are not compatible" );
	FeatureRule( Allow1( F_PARALLAX_OCCLUSION, F_DIFFUSE_WRAP ), "Parallax Occlusion and Diffuse Wrap are not compatible" );
	FeatureRule( Allow1( F_PARALLAX_OCCLUSION, F_ADDITIVE_BLEND ), "Parallax Occlusion and Additive Blend are not compatible" );
	FeatureRule( Allow1( F_PARALLAX_OCCLUSION, F_DETAIL_TEXTURE ), "Parallax Occlusion and Detail Texture are not compatible" );
	FeatureRule( Allow1( F_PARALLAX_OCCLUSION, F_METALNESS_TEXTURE ), "Parallax Occlusion and Metalness Texture are not compatible" );
	FeatureRule( Allow1( F_PARALLAX_OCCLUSION, F_RETRO_REFLECTIVE ), "Parallax Occlusion and Retro Reflective are not compatible" );
}

COMMON
{
	#define ENABLE_NORMAL_MAPS
	#define COLOR_SAMPLER_DEFINED
	// two-sidedness is material state, not a shader variant (as in the shipped complex)
	#define MATERIAL_CONTROLLED_BACKFACES

	#include "system.fxc"
	#include "vr_common.fxc"
}

struct VS_INPUT
{
	#include "vr_shared_standard_vs_input.fxc"
};

struct PS_INPUT
{
	#include "vr_shared_standard_ps_input.fxc"
};

VS
{
	StaticCombo( S_DETAIL_TEXTURE, F_DETAIL_TEXTURE, Sys( ALL ) );

	#include "vr_shared_standard_vs_code.fxc"

	PS_INPUT MainVs( VS_INPUT i )
	{
		PS_INPUT o = VS_SharedStandardProcessing( i );
		return VS_CommonProcessing_Post( o );
	}
}

PS
{
	StaticCombo( S_ALPHA_TEST, F_ALPHA_TEST, Sys( ALL ) );
	StaticCombo( S_TRANSLUCENT, F_TRANSLUCENT, Sys( ALL ) );
	StaticCombo( S_ADDITIVE_BLEND, F_ADDITIVE_BLEND, Sys( ALL ) );
	StaticCombo( S_TINT_MASK, F_TINT_MASK, Sys( ALL ) );
	StaticCombo( S_ANISOTROPIC_GLOSS, F_ANISOTROPIC_GLOSS, Sys( ALL ) );
	StaticCombo( S_RETRO_REFLECTIVE, F_RETRO_REFLECTIVE, Sys( ALL ) );
	StaticCombo( S_SELF_ILLUM, F_SELF_ILLUM, Sys( ALL ) );
	StaticCombo( S_DETAIL_TEXTURE, F_DETAIL_TEXTURE, Sys( ALL ) );
	StaticCombo( S_METALNESS_TEXTURE, F_METALNESS_TEXTURE, Sys( ALL ) );
	// the shared code tests these with a plain if, not #if: specialization constants, they don't multiply the variants
	StaticCombo( S_SCALE_NORMAL_MAP, F_SCALE_NORMAL_MAP, Sys( ALL ), ShaderConstant() );
	StaticCombo( S_ENABLE_NORMAL_SELF_SHADOW, F_ENABLE_NORMAL_SELF_SHADOW, Sys( ALL ), ShaderConstant() );
	StaticCombo( S_USE_BENT_NORMALS, F_USE_BENT_NORMALS, Sys( ALL ), ShaderConstant() );
	StaticCombo( S_TRANSMISSIVE_BACKFACE_NDOTL, F_TRANSMISSIVE_BACKFACE_NDOTL, Sys( ALL ), ShaderConstant() );
	StaticCombo( S_CLOTH_SHADING, F_CLOTH_SHADING, Sys( ALL ), ShaderConstant() );
	DynamicCombo( D_OPAQUE_FADE, 0..1, Sys( ALL ) );

	// the engine sets opaque fade (alpha to coverage) on translucent materials too; their alpha blends, and with coverage
	// they would draw solid, so for translucent materials it is as if there was no such combo
	#if ( S_TRANSLUCENT )
		#undef D_OPAQUE_FADE
		#define D_OPAQUE_FADE 0
	#endif

	// opaque materials keep metalness in the color's alpha and have no metalness texture of their own; translucent and
	// alpha-tested ones use that alpha, so their metalness (with the retro-reflective mask) is a separate texture, as in
	// the shared code
	#if ( S_METALNESS_TEXTURE && !S_ALPHA_TEST && !S_TRANSLUCENT && !S_RETRO_REFLECTIVE )
		#define METALNESS_IN_COLOR
	#endif

	// bent normals and transmission are textures only for materials with these features
	#define BENT_NORMAL_ACTIVE_IF ActiveIf( F_USE_BENT_NORMALS );

	// color as in the shipped complex: always g_tColor (without its own, the shared code calls it g_tColor1 or g_tColor2,
	// and materials don't find their textures); the TextureColor input is declared by the shared code
	#if ( S_TRANSLUCENT )
		Texture2D g_tColor < Channel( RGB, AlphaWeighted( TextureColor, TextureTranslucency ), Srgb );
							 Channel( A, Box( TextureTranslucency ), Linear );
							 OutputFormat( BC7 ); SrgbRead( true ); >;
	#elif ( S_ALPHA_TEST )
		Texture2D g_tColor < Channel( RGB, AlphaWeighted( TextureColor, TextureTranslucency ), Srgb );
							 Channel( A, PreserveCoverage( TextureTranslucency ), Linear );
							 OutputFormat( BC7 ); SrgbRead( true ); >;
	#elif defined( METALNESS_IN_COLOR )
		Texture2D g_tColor < Channel( RGB, Box( TextureColor ), Srgb );
							 Channel( A, Box( TextureMetalness ), Linear );
							 OutputFormat( BC7 ); SrgbRead( true ); >;
	#else
		Texture2D g_tColor < Channel( RGB, Box( TextureColor ), Srgb ); OutputFormat( DXT1 ); SrgbRead( true ); >;
	#endif

	#include "vr_shared_standard_ps_code.fxc"

	float g_flAmbientOcclusionDirectDiffuse < Default( 0.0 ); Range( 0.0, 1.0 ); UiGroup( "Ambient Occlusion/20" ); >;
	float g_flAmbientOcclusionDirectSpecular < Default( 0.0 ); Range( 0.0, 1.0 ); UiGroup( "Ambient Occlusion/30" ); >;

	CreateInputTexture2D( TextureTransmissiveColor, Srgb, 8, "", "_color", "Transmission", Default3( 0.0, 0.0, 0.0 ) );
	Texture2D g_tTransmissiveColor < Channel( RGB, Box( TextureTransmissiveColor ), Srgb ); OutputFormat( DXT1 ); SrgbRead( true ); ActiveIf( F_TRANSMISSIVE_BACKFACE_NDOTL ); >;

	PS_OUTPUT MainPs( PS_INPUT i )
	{
		FinalCombinerInput_t f = PS_SharedStandardProcessing( i );
		f.flAmbientOcclusionDirectDiffuse = g_flAmbientOcclusionDirectDiffuse;
		f.flAmbientOcclusionDirectSpecular = g_flAmbientOcclusionDirectSpecular;

		if ( S_TRANSMISSIVE_BACKFACE_NDOTL != 0 )
			f.vTransmissiveMask = Tex2DS( g_tTransmissiveColor, g_sAniso, i.vTextureCoords.xy ).rgb;

		LightingTerms_t lightingTerms = InitLightingTerms();
		PS_OUTPUT o = PS_FinalCombinerDoLighting( f, lightingTerms );
		return PS_FinalCombinerDoPostProcessing( f, lightingTerms, o );
	}
}
