// Tdarr "Custom JS Function" body for the Shrink Oversized Video flow.
// Pasted verbatim into the flow by scripts/tdarr-shrink-flow.py; edit here,
// then re-run that script.
//
// Runs after "Begin Command". Output 1: the ffmpegCommand has been set up to
// re-encode, continue to Execute. Output 2: leave the file alone.
//
// Targets come from a VMAF sweep on real library files (2026-09-13): cq 28
// scored 96.4-96.8 on 4K HDR and cq 26 scored ~96 on 1080p, measured
// against the source. The cap bounds grainy or dark material, which is
// where NVENC spends the most bits.
module.exports = async (args) => {
  const tiers = [
    // minWidth, re-encode when the video stream is above `aboveKbps`
    { name: '2160p', minWidth: 3200, aboveKbps: 12000, cq: 28, capKbps: 8000 },
    { name: '1080p', minWidth: 1600, aboveKbps: 8000, cq: 26, capKbps: 4000 },
    { name: '720p', minWidth: 1100, aboveKbps: 4000, cq: 26, capKbps: 2000 },
  ];
  const lossless = ['truehd', 'mlp', 'flac', 'alac'];

  const skip = (why) => {
    args.jobLog(`shrink: leaving alone, ${why}`);
    return { outputFileObj: args.inputFileObj, outputNumber: 2, variables: args.variables };
  };

  const cmd = args.variables.ffmpegCommand;
  const probe = args.inputFileObj.ffProbeData || {};
  const videos = cmd.streams.filter((s) => s.codec_type === 'video');
  if (videos.length !== 1) return skip(`${videos.length} video streams`);
  const v = videos[0];

  if (['av1', 'vp9'].includes(v.codec_name)) return skip(`already ${v.codec_name}`);
  if (!/^(yuv420p|yuv420p10le|nv12|p010le)$/.test(v.pix_fmt || '')) return skip(`pix_fmt ${v.pix_fmt}`);
  if (['tt', 'bb', 'tb', 'bt'].includes(v.field_order)) return skip('interlaced');

  const tier = tiers.find((t) => Number(v.width) >= t.minWidth);
  if (!tier) return skip(`width ${v.width} is below 720p`);

  // Dolby Vision: NVENC encodes the base layer only, and shrink-restore.js
  // re-injects the RPU afterwards (profile 7 becomes 8.1). That needs a
  // base layer that is itself HDR10/SDR/HLG. Profile 5 has none: its base
  // is IPTPQc2 and would come out with wrong colors.
  // Tdarr's stored ffprobe has no stream side data, so ask ffprobe here.
  let sideData = v.side_data_list;
  if (!sideData) {
    try {
      const out = require('child_process').execFileSync('ffprobe', [
        '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'stream_side_data=dv_profile,dv_bl_signal_compatibility_id',
        '-of', 'json', args.inputFileObj._id,
      ], { encoding: 'utf8', timeout: 60000 });
      sideData = ((JSON.parse(out).streams || [])[0] || {}).side_data_list || [];
    } catch (e) {
      return skip(`ffprobe for Dolby Vision failed: ${e.message}`);
    }
  }
  const dv = sideData.find((x) => x.dv_profile !== undefined);
  if (dv && ![1, 2, 4, 6].includes(Number(dv.dv_bl_signal_compatibility_id))) {
    return skip(`Dolby Vision profile ${dv.dv_profile} with no fallback layer`);
  }

  // The output keeps the source's extension: a new one would orphan the
  // file from Sonarr/Radarr. AVI and WebM cannot carry HEVC, so those stay
  // as they are. The Dolby Vision restore remuxes with mkvmerge, so DV
  // outside MKV stays too.
  const container = cmd.container;
  if (['avi', 'webm'].includes(container)) return skip(`${container} cannot carry HEVC`);
  if (dv && container !== 'mkv') return skip(`Dolby Vision in ${container}, the restore needs MKV`);

  // Video bitrate. MKV rarely has stream bit_rate; the BPS tag and
  // MediaInfo usually do. Last resort: overall minus audio.
  const tagBps = (s) => Number((s.tags || {}).BPS || (s.tags || {})['BPS-eng'] || s.bit_rate || 0);
  const mi = ((args.inputFileObj.mediaInfo || {}).track || []).find((t) => t['@type'] === 'Video');
  let bps = tagBps(v) || Number((mi || {}).BitRate || 0);
  if (!bps) {
    const overall = Number((probe.format || {}).bit_rate || 0);
    const audio = cmd.streams.filter((s) => s.codec_type === 'audio').reduce((n, s) => n + tagBps(s), 0);
    bps = overall - audio;
  }
  const kbps = Math.round(bps / 1000);
  if (!kbps) return skip('could not determine video bitrate');
  if (kbps <= tier.aboveKbps) return skip(`${tier.name} at ${kbps} kbps, threshold ${tier.aboveKbps}`);

  const tenBit = /10/.test(v.pix_fmt);
  const hdr = ['smpte2084', 'arib-std-b67'].includes(v.color_transfer);

  v.outputArgs.push(
    '-c:{outputIndex}', 'hevc_nvenc',
    '-preset', 'p6', '-tune', 'hq',
    '-rc', 'vbr', '-cq', String(tier.cq), '-b:v', '0',
    '-maxrate', `${tier.capKbps}k`, '-bufsize', `${tier.capKbps * 2}k`,
    '-spatial_aq', '1', '-temporal_aq', '1', '-rc-lookahead', '32',
    '-bf', '3', '-b_ref_mode', 'middle',
    '-profile:v', tenBit ? 'main10' : 'main',
  );
  // Carry the source's color tags explicitly so HDR10/HLG signalling never
  // depends on the decoder passing them through.
  for (const [opt, key] of [['-color_primaries', 'color_primaries'], ['-color_trc', 'color_transfer'], ['-colorspace', 'color_space']]) {
    if (v[key] && v[key] !== 'unknown' && v[key] !== 'reserved') v.outputArgs.push(opt, v[key]);
  }
  if (['mp4', 'm4v', 'mov'].includes(container)) v.outputArgs.push('-tag:{outputIndex}', 'hvc1');
  // ffmpeg picks its ipod muxer for .m4v, and that one rejects HEVC.
  if (container === 'm4v') cmd.overallOuputArguments.push('-f', 'mp4');

  // Audio: lossy tracks are copied untouched. Lossless tracks are the big
  // ones; they become E-AC-3 (5.1 at 640k, stereo at 224k). TrueHD Atmos
  // loses its height objects in the process.
  let converted = 0;
  for (const s of cmd.streams) {
    if (s.codec_type === 'data') {
      s.removed = true;
      continue;
    }
    if (s.codec_type !== 'audio') continue;
    const isLossless = lossless.includes(s.codec_name)
      || (s.codec_name || '').startsWith('pcm_')
      || (s.codec_name === 'dts' && /MA/.test(s.profile || ''));
    if (!isLossless) continue;
    const ch = Number(s.channels || 2);
    s.outputArgs.push('-c:{outputIndex}', 'eac3', '-b:{outputIndex}', ch > 2 ? '640k' : '224k');
    if (ch > 6) s.outputArgs.push('-ac:{outputIndex}', '6');
    // A title naming the old format ("TrueHD Atmos 7.1") would now lie in
    // every player's track menu. Titles like "Commentary" are left alone.
    const title = (s.tags || {}).title || '';
    if (/truehd|atmos|dts|flac|pcm|lossless|7\.1/i.test(title)) {
      s.outputArgs.push(`-metadata:s:{outputIndex}`, `title=E-AC-3 ${ch > 2 ? '5.1' : '2.0'}`);
    }
    converted += 1;
  }

  cmd.overallInputArguments.push('-hwaccel', 'cuda', '-hwaccel_output_format', 'cuda');
  cmd.overallOuputArguments.push('-max_muxing_queue_size', '9999');
  cmd.shouldProcess = true;

  args.jobLog(`shrink: ${tier.name} ${v.codec_name} at ${kbps} kbps${hdr ? ' HDR' : ''}${dv ? ` DV${dv.dv_profile}.${dv.dv_bl_signal_compatibility_id} (RPU restored after encode)` : ''}`
    + ` -> hevc cq ${tier.cq} cap ${tier.capKbps}k, ${converted} lossless audio track(s) to E-AC-3`);
  return { outputFileObj: args.inputFileObj, outputNumber: 1, variables: args.variables };
};
