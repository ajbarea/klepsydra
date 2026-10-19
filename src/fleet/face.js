// Point an <img> at a session's face: the 96 px file, or the 192 px one where
// the face is drawn larger than 96 device pixels. SVG faces are one file.
export function showFace(img, face, face2x, cssPx) {
  img.sizes = `${Math.ceil(cssPx)}px`;
  img.srcset = face === face2x ? "" : `${face} 96w, ${face2x} 192w`;
  if (img.getAttribute("src") !== face2x) img.src = face2x;
}
