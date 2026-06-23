"""
RAMLabeler — wraps Recognize Anything Model Plus for open-vocabulary tagging.

Replaces CLIPLabeler in label_pipeline.py; load via load_labeler("ram").
"""

from __future__ import annotations


def load_labeler(backend: str, threshold: float = 0.20):
    if backend == "ram":
        return RAMLabeler()
    if backend == "clip":
        from label_pipeline import CLIPLabeler
        return CLIPLabeler(threshold)
    return None


class RAMLabeler:
    """Open-vocabulary tagger using RAM+ (6400+ categories, no fixed label list)."""

    def __init__(self, image_size: int = 384, device: str = ""):
        import torch
        from ram.models import ram_plus
        from ram import get_transform

        if device:
            self._device = device
        elif torch.cuda.is_available():
            self._device = "cuda"
        elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            self._device = "mps"
        else:
            self._device = "cpu"

        from huggingface_hub import hf_hub_download
        weights_path = hf_hub_download(
            repo_id="xinyu1205/recognize-anything-plus-model",
            filename="ram_plus_swin_large_14m.pth",
        )
        self._transform = get_transform(image_size=image_size)
        model = ram_plus(
            pretrained=weights_path,
            image_size=image_size,
            vit="swin_l",
        )
        model.eval()
        self._model = model.to(self._device)

    def label(self, img_path: str) -> list[tuple[str, float]]:
        """Returns (tag, 1.0) pairs — RAM is binary (present / absent)."""
        from PIL import Image
        import torch
        from ram import inference_ram

        img = self._transform(Image.open(img_path).convert("RGB"))
        img = img.unsqueeze(0).to(self._device)
        with torch.no_grad():
            res = inference_ram(img, self._model)
        tags_str: str = res[0]
        return [(t.strip(), 1.0) for t in tags_str.split("|") if t.strip()]
