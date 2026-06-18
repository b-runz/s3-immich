IMAGENET_LABELS = [
    "person", "animal", "dog", "cat", "bird", "car", "bicycle", "food",
    "building", "landscape", "beach", "mountain", "forest", "city", "night",
    "indoor", "outdoor", "sport", "celebration", "document", "text",
]


def load_labeler(backend: str, threshold: float = 0.20):
    if backend == "clip":
        return CLIPLabeler(threshold)
    return None


class CLIPLabeler:
    def __init__(self, threshold: float = 0.20):
        import open_clip
        self._model, _, self._preprocess = open_clip.create_model_and_transforms(
            "ViT-B-32", pretrained="openai"
        )
        self._tokenizer = open_clip.get_tokenizer("ViT-B-32")
        self._threshold = threshold
        self._model.eval()
        self._text_features = None

    def label(self, img_path: str) -> list[tuple[str, float]]:
        """Returns list of (label, confidence) pairs above threshold."""
        import torch
        from PIL import Image

        if self._text_features is None:
            prompts = [f"a photo of {label}" for label in IMAGENET_LABELS]
            texts = self._tokenizer(prompts)
            with torch.no_grad():
                self._text_features = self._model.encode_text(texts)
                self._text_features /= self._text_features.norm(dim=-1, keepdim=True)

        img = self._preprocess(Image.open(img_path).convert("RGB")).unsqueeze(0)
        with torch.no_grad():
            img_feat = self._model.encode_image(img)
            img_feat /= img_feat.norm(dim=-1, keepdim=True)
            logit_scale = self._model.logit_scale.exp()
            probs = (logit_scale * img_feat @ self._text_features.T).softmax(dim=-1)[0]

        return [
            (IMAGENET_LABELS[i], float(probs[i]))
            for i in range(len(IMAGENET_LABELS))
            if float(probs[i]) >= self._threshold
        ]
