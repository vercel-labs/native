// Each row's avatar, in row order. The files are in public/, which a build copies into the app's
// root as they are: the src below is built from this data at run time, so the build never sees a
// literal naming an avatar and ships them anyway.

const avatars = ["a1.png", "a2.png", "a3.png", "a4.png"];

for (let i = 0; i < avatars.length; i++) {
  const img = document.getElementById("avatar-" + i) as HTMLImageElement;
  img.src = "/avatars/" + avatars[i];
}
(document.getElementById("me-avatar") as HTMLImageElement).src = "/avatars/" + avatars[0];

const btn = document.getElementById("resend")!;
btn.addEventListener("click", () => {
  const row = document.getElementById("last")!;
  row.style.backgroundColor = "#f0fdf4";
  btn.textContent = "Invite sent ✓";
  btn.style.backgroundColor = "#16a34a";
});
