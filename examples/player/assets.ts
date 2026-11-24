// The player builds cover and track URLs from its data at run time, and a build only copies the
// files it can see: the images and styles in the markup, and the files a script names in a
// literal fetch() or import. These literals keep every cover and track in the bundle. Nothing
// calls this function; it is here for the build to read.

export function bundleAssets(): void {
  fetch("art/still-harbor.jpg");
  fetch("art/neon-orchard.jpg");
  fetch("art/paper-planes.jpg");
  fetch("art/low-tide.jpg");
  fetch("art/glasshouse.jpg");
  fetch("art/superbloom.jpg");
  fetch("art/night-bus.jpg");
  fetch("art/static-bloom.jpg");
  fetch("art/copper-sky.jpg");
  fetch("art/satellite-hearts.jpg");
  fetch("art/evergreen.jpg");
  fetch("art/midnight-garden.jpg");

  fetch("audio/still-harbor-1.ogg");
  fetch("audio/still-harbor-2.ogg");
  fetch("audio/still-harbor-3.ogg");
  fetch("audio/neon-orchard-1.ogg");
  fetch("audio/neon-orchard-2.ogg");
  fetch("audio/neon-orchard-3.ogg");
  fetch("audio/paper-planes-1.ogg");
  fetch("audio/paper-planes-2.ogg");
  fetch("audio/paper-planes-3.ogg");
  fetch("audio/low-tide-1.ogg");
  fetch("audio/low-tide-2.ogg");
  fetch("audio/low-tide-3.ogg");
  fetch("audio/glasshouse-1.ogg");
  fetch("audio/glasshouse-2.ogg");
  fetch("audio/glasshouse-3.ogg");
  fetch("audio/superbloom-1.ogg");
  fetch("audio/superbloom-2.ogg");
  fetch("audio/superbloom-3.ogg");
  fetch("audio/night-bus-1.ogg");
  fetch("audio/night-bus-2.ogg");
  fetch("audio/night-bus-3.ogg");
  fetch("audio/static-bloom-1.ogg");
  fetch("audio/static-bloom-2.ogg");
  fetch("audio/static-bloom-3.ogg");
  fetch("audio/copper-sky-1.ogg");
  fetch("audio/copper-sky-2.ogg");
  fetch("audio/copper-sky-3.ogg");
  fetch("audio/satellite-hearts-1.ogg");
  fetch("audio/satellite-hearts-2.ogg");
  fetch("audio/satellite-hearts-3.ogg");
  fetch("audio/evergreen-1.ogg");
  fetch("audio/evergreen-2.ogg");
  fetch("audio/evergreen-3.ogg");
  fetch("audio/midnight-garden-1.ogg");
  fetch("audio/midnight-garden-2.ogg");
  fetch("audio/midnight-garden-3.ogg");
}
