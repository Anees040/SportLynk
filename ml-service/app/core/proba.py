"""
Probability wrapper for the sentiment classifier  —  S.4 Wave B

WHY THIS EXISTS
LinearSVC is the strongest linear model on this corpus (char-only, uncalibrated:
0.76 exam vs 0.715 for the calibrated word+char build), but it has no
`predict_proba` — serving needs one, because the router returns per-class
confidence and FR9.10 gates the toxicity flag on P(negative).

The obvious fix, `CalibratedClassifierCV`, was measured and rejected. Sigmoid
calibration on this data did two harmful things at once:

  * it COST ACCURACY — the calibrated build fell to 0.715 while the identical
    uncalibrated model scored 0.755–0.76 on the same exam; and
  * it STARVED THE MINORITY CLASS — negative recall collapsed to 0.44
    (precision 0.94): the Platt sigmoids, fit per-fold on few negative rows,
    smoothed the decision boundary away from the class the product most needs
    to catch (68/200 of the exam is negative).

The insight this class encodes: we do not actually need *calibrated* numbers,
we need *monotonic* ones. `softmax(decision_function(x))` is a strictly
increasing transform of the SVM margins, so

    argmax(softmax(scores)) == argmax(scores) == LinearSVC.predict(x)

exactly — the probabilities ride on top of the uncalibrated model without moving
a single prediction. Accuracy and negative recall are those of the bare
LinearSVC; the outputs are just now a proper distribution over the three labels.

WHY IT LIVES IN core/
The trained Pipeline pickles its final estimator BY REFERENCE, exactly as it
does for `text_norm.prep_word`. For `joblib.load` to reconstruct the artifact at
serve time, the class must be importable under the same dotted path that was in
effect at train time. Training does `from app.core import proba`; serving loads
`app.core.proba.SoftmaxSVC`. Same module, same path, no train/serve skew — the
one rule that makes the frozen-contract pattern hold.

WHAT IT IS NOT
These are confidence scores, not calibrated posteriors. A 0.82 here does not mean
"right 82% of the time"; it means the margin for that class is comfortably the
largest. The model card says so, and the toxicity threshold is chosen against
these scores, not against a calibrated probability.
"""

from __future__ import annotations

import numpy as np
from sklearn.base import BaseEstimator, ClassifierMixin
from sklearn.svm import LinearSVC

__all__ = ("SoftmaxSVC",)


class SoftmaxSVC(BaseEstimator, ClassifierMixin):
    """A LinearSVC whose ``predict_proba`` is ``softmax(decision_function)``.

    Behaves as a drop-in classifier for a scikit-learn ``Pipeline``: ``fit``,
    ``predict``, ``decision_function``, ``predict_proba``, ``predict_log_proba``.
    ``predict`` delegates to the wrapped SVM, so predictions are byte-for-byte
    those of an uncalibrated ``LinearSVC(C=..., class_weight=...)`` — the softmax
    is monotonic and never changes the argmax.

    Constructor stores hyperparameters only (the scikit-learn estimator contract,
    so ``clone`` / ``get_params`` work); the ``LinearSVC`` is built in ``fit``.

    Parameters
    ----------
    C, class_weight, random_state
        Forwarded verbatim to the wrapped ``LinearSVC``.
    temperature
        Divides the margins before softmax. ``1.0`` is plain softmax; larger
        values soften the distribution. It CANNOT change any prediction
        (dividing all scores by a positive constant preserves the argmax); it
        only reshapes the confidences. Default ``1.0`` — we tune the model, not
        the thermometer.
    """

    def __init__(
        self,
        *,
        C: float = 1.0,
        class_weight: str | dict | None = "balanced",
        random_state: int | None = None,
        temperature: float = 1.0,
    ) -> None:
        self.C = C
        self.class_weight = class_weight
        self.random_state = random_state
        self.temperature = temperature

    # ── training ───────────────────────────────────────────────────────────
    def fit(self, X, y, sample_weight=None) -> "SoftmaxSVC":
        if self.temperature <= 0:
            raise ValueError(f"temperature must be > 0, got {self.temperature!r}")
        self.svc_ = LinearSVC(
            C=self.C,
            class_weight=self.class_weight,
            random_state=self.random_state,
        )
        self.svc_.fit(X, y, sample_weight=sample_weight)
        # Exposed so ClassifierMixin.score and downstream label bookkeeping work,
        # and so predict_proba columns line up with these labels in this order.
        self.classes_ = self.svc_.classes_
        return self

    # ── inference ──────────────────────────────────────────────────────────
    def decision_function(self, X):
        return self.svc_.decision_function(X)

    def predict(self, X):
        # Delegated on purpose: identical to a bare LinearSVC, which is exactly the
        # model the tuning sweep measured. softmax(scores) has the same argmax, so
        # this stays consistent with predict_proba below.
        return self.svc_.predict(X)

    def predict_proba(self, X):
        scores = np.asarray(self.decision_function(X), dtype=float)
        # Binary LinearSVC returns a 1-D margin; lift it to the two-column form
        # [-m, +m] so softmax yields the usual sigmoid pair. Multiclass (our case,
        # 3 labels) already comes back (n_samples, n_classes) one-vs-rest.
        if scores.ndim == 1:
            scores = np.column_stack([-scores, scores])
        scores = scores / self.temperature
        # Subtract the row max before exp: standard log-sum-exp stabilisation,
        # keeps exp() from overflowing on large margins. Does not affect the result.
        scores = scores - scores.max(axis=1, keepdims=True)
        np.exp(scores, out=scores)
        scores /= scores.sum(axis=1, keepdims=True)
        return scores

    def predict_log_proba(self, X):
        return np.log(self.predict_proba(X))
