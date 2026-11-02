using Sandbox.Rendering;

namespace Sandbox;

/// <summary>
/// Light bounced off what's on screen: the glow of a lit wall on the floor next to it, the colour of a bright floor on
/// the ceiling above. Takes over from the baked indirect lighting in the directions its rays can see.
/// </summary>
[Title( "Global Illumination (SSGI)" )]
[Category( "Post Processing" )]
[Icon( "wb_twilight" )]
public sealed class ScreenSpaceGlobalIllumination : BasePostProcess<ScreenSpaceGlobalIllumination>
{
	[ConVar( "r_ssgi_quality", Min = 0, Max = 3, Help = "Screen space global illumination quality (0: off, 1: low, 2: med, 3: high)" )]
	internal static int UserQuality { get; set; } = 3;

	[ConVar( "r_ssgi_debug", ConVarFlags.Cheat, Help = "Debug: show the bounced light on its own, without the rest of the frame" )]
	internal static bool ShowDebug { get; set; } = false;

	/// <summary>
	/// How much of the bounced light to apply, 0 is as good as off. Has no impact on performance.
	/// </summary>
	[Property, Range( 0, 2 ), Category( "Properties" )]
	public float Intensity { get; set; } = 1.0f;

	Texture BlueNoise { get; set; } = Texture.Load( "textures/dev/blue_noise_256.vtex" );

	enum Passes
	{
		Trace,
		Resolve,
		Accumulate,
		Filter,
		Upsample
	}

	CommandList commands = new CommandList( "Global Illumination" );
	CommandList commandsLastFrame = new CommandList( "Global Illumination (Last Frame)" );

	private static ComputeShader GiCs = new ComputeShader( "screen_space_global_illumination_cs" );
	private static Material DebugShader = Material.FromShader( "shaders/screen_space_global_illumination_debug.shader" );

	// A GPU profiler row per pass. The async compute queue has no timestamps, so +r_managed_async_compute 0 to see them
	static readonly ProfilingSampler[] PassSamplers =
	[
		new( "SSGI Trace" ),
		new( "SSGI Resolve" ),
		new( "SSGI Accumulate" ),
		new( "SSGI Filter" ),
		new( "SSGI Upsample" )
	];

	// What lives on between frames, at half resolution apart from the result. Owned rather than pooled: the lighting
	// shader reads the result through the camera's attributes, so its bindless index has to hold from one frame to the
	// next, and a camera's reservoirs are its own
	Vector2Int size;
	Texture[] reservoirHit = new Texture[2];
	Texture[] reservoirLight = new Texture[2];
	Texture[] reservoirNormal = new Texture[2];
	Texture[] samples = new Texture[2];
	Texture traceInfo;
	Texture lightA;
	Texture lightB;
	Texture history;
	// Two of these: the forward pass of the frame before may still be reading one when the early queue writes the next
	Texture[] result = new Texture[2];
	int frame;

	// The camera the result is published to, so it can be taken back
	SceneCamera published;

	protected override void OnEnabled()
	{
		base.OnEnabled();

		commandsLastFrame.Reset();
		commandsLastFrame.Attributes.GrabFrameTexture( "LastFrameColor" );
	}

	protected override void OnDisabled()
	{
		base.OnDisabled();

		Unpublish();
		DisposeTextures();
	}

	/// <summary>
	/// Reads the normals G-buffer the depth-normals prepass writes (<c>NormalsGBuffer</c>).
	/// </summary>
	internal override bool NeedsDepthNormals => true;

	// Compute dispatches and barriers over the depth chain, normals and its own history
	internal override PostProcessQueue? EarlyQueue => PostProcessQueue.AsyncCompute;

	public override void Render()
	{
		commands.Reset();

		var lastFrame = commandsLastFrame.Attributes.GetRenderTarget( "LastFrameColor" )?.ColorTarget;
		if ( UserQuality <= 0 || lastFrame is null || lastFrame.Width < 2 )
		{
			Unpublish();

			// Keep grabbing, the first traced frame wants one
			if ( UserQuality > 0 )
				InsertCommandList( commandsLastFrame, Stage.AfterOpaque, 0, "Global Illumination" );

			return;
		}

		EnsureTextures( lastFrame.Width, lastFrame.Height );

		// Last frame's reservoirs and sample counts are read while this frame's are written
		int ping = frame & 1;
		int pong = ping ^ 1;

		commands.Attributes.Set( "PreviousFrameColorIndex", lastFrame.Index );
		commands.Attributes.Set( "BlueNoise", BlueNoise );
		commands.Attributes.Set( "Frame", frame );
		commands.Attributes.Set( "Intensity", GetWeighted( x => x.Intensity, 1.0f ) );
		commands.Attributes.SetCombo( "D_QUALITY", (UserQuality - 1).Clamp( 0, 2 ) );

		// Grabbed at AfterOpaque and read here as an SRV; the grab leaves it in whatever state it was
		commands.ResourceBarrierTransition( lastFrame, ResourceState.NonPixelShaderResource );

		using ( commands.ProfileScope( PassSamplers[(int)Passes.Trace] ) )
		{
			commands.Attributes.Set( "ReservoirHit", reservoirHit[pong] );
			commands.Attributes.Set( "ReservoirLight", reservoirLight[pong] );
			commands.Attributes.Set( "ReservoirNormal", reservoirNormal[pong] );
			commands.Attributes.Set( "Samples", samples[pong] );
			Output( "OutReservoirHit", reservoirHit[ping] );
			Output( "OutReservoirLight", reservoirLight[ping] );
			Output( "OutReservoirNormal", reservoirNormal[ping] );
			Output( "OutTraceInfo", traceInfo );
			Dispatch( Passes.Trace, size );
			Done( reservoirHit[ping] );
			Done( reservoirLight[ping] );
			Done( reservoirNormal[ping] );
			Done( traceInfo );
		}

		using ( commands.ProfileScope( PassSamplers[(int)Passes.Resolve] ) )
		{
			commands.Attributes.Set( "ReservoirHit", reservoirHit[ping] );
			commands.Attributes.Set( "ReservoirLight", reservoirLight[ping] );
			commands.Attributes.Set( "ReservoirNormal", reservoirNormal[ping] );
			commands.Attributes.Set( "TraceInfo", traceInfo );
			Output( "OutLight", lightA );
			Dispatch( Passes.Resolve, size );
			Done( lightA );
		}

		// The history is last frame's first filter step, read before this frame's overwrites it
		using ( commands.ProfileScope( PassSamplers[(int)Passes.Accumulate] ) )
		{
			commands.Attributes.Set( "Light", lightA );
			commands.Attributes.Set( "History", history );
			Output( "OutLight", lightB );
			Output( "OutSamples", samples[ping] );
			Dispatch( Passes.Accumulate, size );
			Done( lightB );
			Done( samples[ping] );
		}

		// Three steps, each twice as wide: the first is next frame's history, the last writes the light for real
		using ( commands.ProfileScope( PassSamplers[(int)Passes.Filter] ) )
		{
			commands.Attributes.Set( "Samples", samples[ping] );
			Filter( 1, lightB, history, false );
			Filter( 2, history, lightA, false );
			Filter( 4, lightA, lightB, true );
		}

		using ( commands.ProfileScope( PassSamplers[(int)Passes.Upsample] ) )
		{
			commands.Attributes.Set( "Light", lightB );
			Output( "OutLight", result[ping] );
			Dispatch( Passes.Upsample, new Vector2Int( lastFrame.Width, lastFrame.Height ) );
			commands.ResourceBarrierTransition( result[ping], ResourceState.PixelShaderResource );
		}

		InsertCommandList( commandsLastFrame, Stage.AfterOpaque, 0, "Global Illumination" );
		InsertCommandList( commands, Stage.AfterDepthPrepass, int.MaxValue, "Global Illumination" );

		Publish( result[ping] );
		frame++;

		if ( ShowDebug )
		{
			Attributes.Set( "ScreenSpaceGI", result[ping] );
			BlitSimple( DebugShader, Stage.BeforePostProcess, 100, "Global Illumination (Debug)" );
		}
	}

	void Dispatch( Passes pass, Vector2Int threads )
	{
		commands.Attributes.SetCombo( "D_PASS", (int)pass );
		commands.DispatchCompute( GiCs, threads.x, threads.y, 1 );
	}

	void Filter( int step, Texture from, Texture to, bool last )
	{
		commands.Attributes.Set( "Light", from );
		commands.Attributes.Set( "FilterStep", step );
		commands.Attributes.Set( "FilterLast", last );
		Output( "OutLight", to );
		Dispatch( Passes.Filter, size );
		Done( to );
	}

	// A texture a pass is about to write, and one it has written that the next pass reads
	void Output( string name, Texture texture )
	{
		commands.ResourceBarrierTransition( texture, ResourceState.UnorderedAccess );
		commands.Attributes.Set( name, texture );
	}

	void Done( Texture texture )
	{
		commands.ResourceBarrierTransition( texture, ResourceState.NonPixelShaderResource );
	}

	// The lighting shader finds the result through the camera's attributes. A pipeline texture slot would be the proper
	// home, next to AO and SSR, but those are native and there are two
	void Publish( Texture texture )
	{
		var camera = Camera.SceneCamera;
		if ( camera is null )
			return;

		camera.Attributes.Set( "ScreenSpaceGIIndex", texture.Index );
		camera.Attributes.Set( "ScreenSpaceGIViewport", new Vector2( texture.Width, texture.Height ) );
		published = camera;
	}

	void Unpublish()
	{
		published?.Attributes.Set( "ScreenSpaceGIIndex", 0 );
		published = null;
	}

	void EnsureTextures( int width, int height )
	{
		if ( result[0] is not null && result[0].Width == width && result[0].Height == height )
			return;

		DisposeTextures();
		size = new Vector2Int( (width + 1) / 2, (height + 1) / 2 );

		for ( int i = 0; i < 2; i++ )
		{
			// World positions across a map don't fit half floats
			reservoirHit[i] = Create( "SSGI Reservoir Hit", ImageFormat.RGBA32323232F );
			reservoirLight[i] = Create( "SSGI Reservoir Light" );
			reservoirNormal[i] = Create( "SSGI Reservoir Normal" );
			samples[i] = Create( "SSGI Samples" );
			result[i] = Texture.Create( width, height, ImageFormat.RGBA16161616F ).WithUAVBinding().WithName( "SSGI Result" ).Finish();
		}

		traceInfo = Create( "SSGI Trace Info", ImageFormat.RG1616F );
		lightA = Create( "SSGI Light A" );
		lightB = Create( "SSGI Light B" );
		history = Create( "SSGI History" );

		// Fresh textures hold whatever was there before; frame 0 tells the shader there's no history to read
		frame = 0;
	}

	Texture Create( string name, ImageFormat format = ImageFormat.RGBA16161616F )
	{
		return Texture.Create( size.x, size.y, format ).WithUAVBinding().WithName( name ).Finish();
	}

	void DisposeTextures()
	{
		for ( int i = 0; i < 2; i++ )
		{
			reservoirHit[i]?.Dispose();
			reservoirLight[i]?.Dispose();
			reservoirNormal[i]?.Dispose();
			samples[i]?.Dispose();
			result[i]?.Dispose();
			reservoirHit[i] = reservoirLight[i] = reservoirNormal[i] = samples[i] = result[i] = null;
		}

		traceInfo?.Dispose();
		lightA?.Dispose();
		lightB?.Dispose();
		history?.Dispose();
		traceInfo = lightA = lightB = history = null;
	}
}
