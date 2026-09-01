"""The accept-criterion figure for S.3 Wave B: reports/demand_patterns.png.

WHAT THIS FIGURE IS FOR
-----------------------
The wave's accept criterion is not "a plot exists". It is:

    "curves must look like real Pakistani turf behaviour (7-11pm rush,
     Friday spikes)"

which makes this figure the only VISUAL audit of `generate_bookings.py`. The
generator's twelve self-checks prove the dataset is internally consistent — price
is independent of demand, the contract round-trips, nothing leaks. They cannot
prove it is PLAUSIBLE. Only somebody who has booked a turf in Islamabad can say
that, and they need to see it, not read a correlation coefficient.

So each panel is built to be falsifiable by a domain expert at a glance:

  1. HOUR OF DAY, by sport      The headline claim. Football must show one sharp
                                night peak around 20:00-22:00; cricket must show
                                a SECOND peak at dawn. A third line shows the
                                same football venues during Ramadan, which must
                                collapse through the day and INVERT late at night.
                                If that inversion is not visible, the most
                                distinctive domain claim in the generator is not
                                actually in the data.
  2. DAY OF WEEK                Saturday must lead and Monday must trail. Sunday
                                lands ABOVE Friday, which looks wrong against
                                DOW_MULT (Fri 1.35 > Sun 1.30) until you account
                                for Friday's x0.35 Jummah penalty; all three are
                                labelled so the ordering cannot be misread. This
                                is where the wave prompt's "Fri/Sat/Sun x1.6" was
                                wrong: one weekend flag cannot produce this shape.
  3. MONTH                      Must be BIMODAL — spring and autumn peaks with a
                                summer-heat and a winter trough. A single sine
                                wave, which the prompt asked for, produces one
                                hump and is visibly wrong here. TWO lines, because
                                the raw monthly rate is confounded by Ramadan: it
                                puts March at the annual LOW even though March is
                                a declared spring peak. The Ramadan-excluded line
                                is the one that carries the seasonality claim.
  4. HOUR x DAY heatmap         Where the interactions live: the Friday-daytime
                                Jummah notch, the Friday/Saturday night block,
                                the cricket dawn band. A one-dimensional plot
                                cannot show an interaction; this can.
  5. PRICE RESPONSE             Booking rate against offered price, split peak vs
                                off-peak. Both lines must fall; the off-peak line
                                must fall FASTER. This panel is the evidence that
                                the dataset can teach a pricing model anything at
                                all.

HOW TO READ IT SCEPTICALLY
--------------------------
Every panel plots a rate computed from SIMULATED labels, so a panel agreeing with
the parameter table proves only that the code implements the table. The figure's
real job is the opposite: to let a human disagree with the TABLE. If the 21:00
peak looks too sharp, or the Ramadan late-night lift too strong, that is a
finding about the assumptions, and the assumptions are all in one block of
`generate_bookings.py` with `[ASSUMPTION]` labels on them.

DESIGN
------
Colour, type and grid values come from the project's data-visualisation reference
palette, not from matplotlib's defaults, and a few rules are worth stating because
they are easy to undo by accident:

  * ONE y-axis per panel, always. No twin axes anywhere. Panel 5 compares two
    segments with very different base rates, which is exactly the situation that
    tempts a second axis; it is INDEXED to a common base instead, which is the
    correct fix and keeps a single readable scale.
  * Gridlines are SOLID hairlines in a near-background tone, drawn beneath the
    marks. Dashed grids vibrate against thin data lines.
  * Sequential data (the heatmap) uses ONE hue, light to dark. Never a rainbow:
    rainbow ramps imply category boundaries where the data has none, and they are
    unreadable to colour-blind viewers.
  * Categorical series use a fixed hue order — blue, then orange, then aqua —
    which is the validated trio for adjacent-pair separation under the three
    common colour-vision deficiencies. They are not cycled or reassigned per
    panel: a reader who learns "orange = cricket" in panel 1 must not find orange
    meaning something else in panel 5.
  * Every multi-series panel carries a legend AND direct labels on the lines, so
    identity is never carried by colour alone. Single-series panels get no legend
    box — the panel title names the series.
  * Values are labelled SELECTIVELY, on the points that carry the argument, never
    on every point. A number on every bar turns a chart back into a table.

Text stays in ink tones rather than taking the series colour; the coloured mark
next to a label is what carries identity.

USAGE
-----
    # as part of the generator (default)
    python training/generate_bookings.py

    # standalone, re-rendering from an existing CSV
    python training/demand_plots.py [data/bookings_synth.csv] [reports/demand_patterns.png]

Imported lazily by the generator so that a missing matplotlib cannot stop the
dataset being produced.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import matplotlib

# Non-interactive backend, set before pyplot is imported. Without this, importing
# pyplot on a machine with no display (CI, a container, a bare SSH session) can
# fail or hang trying to find a GUI toolkit — and this module is imported from a
# data-generation script that must never need a screen.
matplotlib.use("Agg")

import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
from matplotlib.colors import LinearSegmentedColormap  # noqa: E402
from matplotlib.gridspec import GridSpec  # noqa: E402
from matplotlib.transforms import blended_transform_factory  # noqa: E402

_ML_ROOT = Path(__file__).resolve().parent.parent
if str(_ML_ROOT) not in sys.path:
    sys.path.insert(0, str(_ML_ROOT))

# Palette. Lifted from the project's visualisation reference rather than chosen
# here, so every chart in reports/ can look like it came from one system.
#
# The three categorical hues are used in this fixed order. That order is not
# aesthetic: blue/orange/aqua is the trio that clears the adjacent-pair
# separation threshold under deuteranopia, protanopia and tritanopia. The
# reference palette's fourth slot is yellow, which sits next to orange and fails
# that test, so a fourth series is not available — if one is ever needed the
# answer is a small multiple, not a new hue.
PAGE = "#f9f9f7"      # page plane, behind the panels
SURFACE = "#fcfcfb"   # chart surface, inside each panel
INK = "#0b0b0b"       # primary ink: titles, key values
INK_2 = "#52514e"     # secondary ink: axis labels, annotations
MUTED = "#898781"     # tick marks
GRID = "#e1e0d9"      # gridline hairline
BASELINE = "#c3c2b7"  # the one spine that stays

BLUE = "#2a78d6"
ORANGE = "#eb6834"
AQUA = "#1baf7a"

# Sequential ramp, one hue, light -> dark. Used only for the heatmap, where the
# encoded quantity is a magnitude.
BLUE_RAMP = (
    "#cde2fb", "#b7d3f6", "#9ec5f4", "#86b6ef", "#6da7ec", "#5598e7", "#3987e5",
    "#2a78d6", "#256abf", "#1c5cab", "#184f95", "#104281", "#0d366b",
)
BLUE_CMAP = LinearSegmentedColormap.from_list("sportlynk_blue", BLUE_RAMP)

DOW_LABELS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
MONTH_LABELS = (
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
)

# The frozen peak window, shaded in panel 1. Imported rather than retyped: this
# figure must show where `is_peak` sits, including where it disagrees
# with the true curve, and a hardcoded 18 here would quietly hide a v2 change.
from app.core import features  # noqa: E402


def _style() -> dict:
    """rcParams for every panel.

    Set explicitly rather than via a named style sheet so the figure renders
    identically on any machine, whatever the local matplotlibrc says.
    """
    return {
        "figure.facecolor": PAGE,
        "savefig.facecolor": PAGE,
        "axes.facecolor": SURFACE,
        "font.family": "sans-serif",
        "font.sans-serif": ["Segoe UI", "DejaVu Sans", "Arial", "sans-serif"],
        "font.size": 10,
        "text.color": INK,
        "axes.titlesize": 12,
        "axes.titleweight": "600",
        "axes.titlecolor": INK,
        "axes.titlelocation": "left",
        "axes.titlepad": 10,
        "axes.labelsize": 9.5,
        "axes.labelcolor": INK_2,
        "axes.edgecolor": BASELINE,
        "axes.linewidth": 0.9,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "axes.axisbelow": True,   # grid UNDER the marks, never over them
        "axes.grid": True,
        "grid.color": GRID,
        "grid.linestyle": "-",    # SOLID. A dashed grid vibrates against thin lines.
        "grid.linewidth": 0.7,
        "xtick.color": MUTED,
        "ytick.color": MUTED,
        "xtick.labelsize": 9,
        "ytick.labelsize": 9,
        "xtick.labelcolor": INK_2,
        "ytick.labelcolor": INK_2,
        "legend.frameon": False,
        "legend.fontsize": 9,
        "legend.labelcolor": INK_2,
        "lines.linewidth": 2.0,   # thin marks
        "lines.markersize": 4.5,
        "lines.solid_capstyle": "round",
    }


def _rate(frame: pd.DataFrame, by: str, mask: pd.Series | None = None) -> pd.Series:
    """Booked share grouped by one column. The only statistic in this figure."""
    sub = frame if mask is None else frame.loc[mask]
    return sub.groupby(by, observed=True)[features.TARGET].mean()


def _annotate(ax, x, y, text: str, dx: float = 0.0, dy: float = 0.012, **kw) -> None:
    """A selective direct label, in ink rather than in the series colour."""
    ax.annotate(
        text,
        (x, y),
        xytext=(x + dx, y + dy),
        color=kw.pop("color", INK),
        fontsize=kw.pop("fontsize", 9),
        fontweight=kw.pop("fontweight", "600"),
        ha=kw.pop("ha", "center"),
        va=kw.pop("va", "bottom"),
        **kw,
    )


# Panel 1 — hour of day. The headline panel.
def _panel_hour(ax, frame: pd.DataFrame) -> None:
    normal = frame["is_ramadan"] == 0
    series = [
        ("Football — ordinary days", BLUE, normal & (frame["sport"] == "football"), "-"),
        ("Cricket — ordinary days", ORANGE, normal & (frame["sport"] == "cricket"), "-"),
        ("Football — Ramadan", AQUA, (frame["is_ramadan"] == 1) & (frame["sport"] == "football"), "-"),
    ]

    # Shade the frozen is_peak window first so it sits behind the lines. Drawn as
    # a band rather than two vertical rules because the point is the extent of the
    # window, and specifically that the true football peak sits at its far end —
    # the visual argument for design DECISION 3(d), that the flag is coarse and
    # the `hour` feature is what carries the real shape.
    ax.axvspan(
        features.PEAK_START_HOUR - 0.5,
        features.PEAK_END_HOUR + 0.5,
        color=GRID,
        alpha=0.55,
        lw=0,
        zorder=0,
    )
    # x in data coords, y in axes coords. Using ax.get_ylim() here would read the
    # default (0, 1) — the lines are not plotted yet, so autoscale has not run, and
    # the label would land above the finished axes and be clipped away.
    ax.text(
        (features.PEAK_START_HOUR + features.PEAK_END_HOUR) / 2,
        0.97,
        f"is_peak = {features.PEAK_START_HOUR}–{features.PEAK_END_HOUR}h",
        transform=blended_transform_factory(ax.transData, ax.transAxes),
        color=MUTED,
        fontsize=8.5,
        ha="center",
        va="top",
    )

    for label, colour, mask, style in series:
        rate = _rate(frame, "hour", mask).sort_index()
        if rate.empty:
            continue
        ax.plot(rate.index, rate.to_numpy(), style, color=colour, label=label, zorder=3)
        # Direct label at the line's end, so identity survives without the legend.
        last_x = int(rate.index[-1])
        ax.plot([last_x], [rate.iloc[-1]], "o", color=colour, ms=5, zorder=4)

    # Selective labels: the two peaks that are the domain claim.
    fb = _rate(frame, "hour", normal & (frame["sport"] == "football")).sort_index()
    ck = _rate(frame, "hour", normal & (frame["sport"] == "cricket")).sort_index()
    if not fb.empty:
        h = int(fb.idxmax())
        _annotate(ax, h, fb.max(), f"football peak {h}:00 · {fb.max():.0%}")
    if not ck.empty:
        dawn = ck.loc[ck.index <= 10]
        if not dawn.empty:
            h = int(dawn.idxmax())
            _annotate(ax, h, dawn.max(), f"cricket dawn peak {h}:00 · {dawn.max():.0%}", ha="left")

    ax.set_title("Booked share by hour of day — the 7–11pm rush, and cricket's dawn peak")
    ax.set_xlabel("hour of day (PKT, slot start)")
    ax.set_ylabel("share of offered slots booked")
    ax.set_xticks(range(int(frame["hour"].min()), int(frame["hour"].max()) + 1))
    ax.yaxis.set_major_formatter(lambda v, _: f"{v:.0%}")
    ax.set_ylim(bottom=0)
    ax.legend(loc="upper left", ncols=1)


# Panel 2 — day of week.
def _panel_dow(ax, frame: pd.DataFrame) -> None:
    rate = _rate(frame, "dow").reindex(range(7))
    # Single series, single hue. Colour must not encode rank, so the tallest bar
    # is not recoloured; the three bars that carry the argument are labelled instead.
    # width 0.72 leaves a clear surface gap between neighbours, and the surface-
    # coloured edge keeps adjacent fills from touching.
    ax.bar(
        range(7),
        rate.to_numpy(),
        width=0.72,
        color=BLUE,
        edgecolor=SURFACE,
        linewidth=1.5,
        zorder=3,
    )
    # Fri, Sat and Sun all carry labels. Labelling only Fri and Sat hid the real
    # ordering: Sunday lands above Friday, because Friday's x0.35 Jummah penalty
    # on 12-16h drags its daily average down further than its x1.20 night bonus
    # lifts it back. That is a genuine consequence of the parameter table — the
    # panel must show it rather than let a title imply Friday is second.
    for d in (4, 5, 6):  # Friday, Saturday, Sunday — the weekend claim
        if not np.isnan(rate.iloc[d]):
            _annotate(ax, d, rate.iloc[d], f"{rate.iloc[d]:.0%}")

    ax.set_title("Booked share by day of week — Sat leads, Mon dead")
    ax.set_xlabel(
        "Pakistan's weekend is Sat–Sun; Friday is a working day, and its midday\n"
        "Jummah dip pulls Friday's daily average below Sunday's"
    )
    ax.set_ylabel("share booked")
    ax.set_xticks(range(7), DOW_LABELS)
    ax.yaxis.set_major_formatter(lambda v, _: f"{v:.0%}")
    ax.set_ylim(bottom=0)
    ax.grid(axis="x", visible=False)  # a categorical axis has no meaningful grid


# Panel 3 — month. Must read as bimodal.
def _panel_month(ax, frame: pd.DataFrame) -> None:
    # Two lines, and the Ramadan-excluded one is the whole point of this panel.
    #
    # The all-days line is confounded, and it looked wrong on first render: it put
    # March at the year's LOW (23%) even though MONTH_MULT[3] = 1.25 makes March
    # the opening of the spring peak. The cause is not seasonality at all. Ramadan
    # 1447 runs 19 Feb - 19 Mar 2026, and Ramadan collapses daytime demand (0.017
    # booked vs 0.185 on ordinary days). So a raw monthly rate is MONTH_MULT x
    # Ramadan, and a reader is invited to conclude the seasonal table is broken.
    #
    # Plotting the Ramadan-excluded line beside it separates the two effects, which
    # makes the panel's claim stronger rather than weaker: the bimodal season is
    # genuinely there, and Ramadan is a larger swing than any month multiplier.
    # Deleting or smoothing the confounded line would have been the dishonest fix.
    rate_all = _rate(frame, "month").reindex(range(1, 13))
    rate_ex = _rate(frame, "month", frame["is_ramadan"] == 0).reindex(range(1, 13))

    # Drawing order matters here. Ramadan touches only two of the twelve months, so
    # these two series are identical for the other ten. Drawn as two equal 2px
    # lines, whichever is on top erases the other and the panel reads as a broken
    # render. So the counterfactual goes underneath as a wider halo with no markers:
    # where the lines agree they read as a blue line with an orange edge ("both series,
    # agreeing"), and where Ramadan bites they separate into two distinct lines.
    # lw 4.0 against the 2.0 default leaves ~1pt of orange proud on each side —
    # enough to read as a deliberate edge at 140 dpi, which 3.4 was not.
    ax.plot(range(1, 13), rate_ex.to_numpy(), "-", color=ORANGE, lw=4.0,
            solid_capstyle="round", label="Excluding Ramadan", zorder=3)
    ax.plot(range(1, 13), rate_all.to_numpy(), "-o", color=BLUE,
            label="All days (as simulated)", zorder=4)

    # Band the months Ramadan touches, read from the data rather than
    # hardcoded: the Hijri window moves ~11 days earlier each solar year, so a
    # literal "Feb-Mar" here would quietly lie for any other --start.
    ram_months = sorted({int(m) for m in frame.loc[frame["is_ramadan"] == 1, "month"].unique()})
    if ram_months:
        ax.axvspan(ram_months[0] - 0.5, ram_months[-1] + 0.5,
                   color=GRID, alpha=0.55, lw=0, zorder=0)
        ax.text(
            (ram_months[0] + ram_months[-1]) / 2,
            0.03,
            "Ramadan",
            transform=blended_transform_factory(ax.transData, ax.transAxes),
            color=MUTED,
            fontsize=8.5,
            ha="center",
            va="bottom",
        )

    # Label the two seasonal peaks off the RAMADAN-EXCLUDED line, because that is
    # the line carrying the seasonality claim, plus its deepest trough. Three
    # points, not twenty-four — the labels are exactly the evidence for "bimodal".
    #
    # NOTE the mask excludes Ramadan, not Eid: Eid al-Fitr 1447 is 20 Mar 2026, the
    # day after Ramadan ends, so March keeps its x0.35 Eid dip and x1.45 rebound.
    # They roughly cancel in a monthly mean, but this line is "Ramadan removed",
    # not "calendar removed", and reports/README.md says so.
    ordered = rate_ex.dropna().sort_values(ascending=False)
    for lo, hi in ((2, 5), (8, 11)):
        group = [m for m in ordered.index if lo <= m <= hi]
        if group:
            m = int(group[0])
            _annotate(ax, m, rate_ex.loc[m], f"{MONTH_LABELS[m - 1]} {rate_ex.loc[m]:.0%}")
    if len(ordered):
        m = int(ordered.index[-1])
        _annotate(ax, m, rate_ex.loc[m], f"{MONTH_LABELS[m - 1]} {rate_ex.loc[m]:.0%}",
                  dy=-0.030, va="top")

    ax.set_title("Booked share by month — bimodal: spring and autumn, not one sine wave")
    ax.set_xlabel("summer heat and monsoon split the year into two seasons")
    ax.set_ylabel("share booked")
    ax.set_xticks(range(1, 13), MONTH_LABELS)
    ax.yaxis.set_major_formatter(lambda v, _: f"{v:.0%}")
    # Explicit headroom. Autoscale stopped just above the tallest point, so the
    # peak's direct label rendered on top of the panel title on first render.
    # nanmax over a list, guarded: this module has a CLI and can be pointed at an
    # arbitrary CSV, and set_ylim(0, nan) raises rather than degrading.
    peak = float(np.nanmax([rate_all.max(), rate_ex.max()]))
    ax.set_ylim(0, peak * 1.28 if np.isfinite(peak) and peak > 0 else 1.0)
    ax.legend(loc="upper left", ncols=1)


# Panel 4 — hour x day heatmap. Where the interactions are visible.
def _panel_heatmap(ax, frame: pd.DataFrame, fig) -> None:
    pivot = (
        frame.pivot_table(index="dow", columns="hour", values=features.TARGET, observed=True)
        .reindex(range(7))
        .sort_index(axis=1)
    )
    hours = [int(h) for h in pivot.columns]
    data = pivot.to_numpy(dtype=np.float64)

    im = ax.imshow(
        data,
        aspect="auto",
        cmap=BLUE_CMAP,
        origin="upper",
        interpolation="nearest",  # never smooth a heatmap; it invents values
        vmin=0.0,
        vmax=float(np.nanmax(data)),
    )
    ax.set_xticks(range(len(hours)), [f"{h}" for h in hours])
    ax.set_yticks(range(7), DOW_LABELS)
    ax.set_title("Booked share by hour x day — the Friday Jummah notch and the weekend night block")
    ax.set_xlabel("hour of day (PKT)")
    ax.grid(visible=False)  # a grid over a heatmap fights the cells

    cbar = fig.colorbar(im, ax=ax, pad=0.012, fraction=0.026)
    cbar.set_label("share of offered slots booked", color=INK_2, fontsize=9)
    cbar.outline.set_visible(False)
    cbar.ax.tick_params(colors=MUTED, labelsize=8.5)
    # A formatter, not set_yticklabels. A colorbar carries its own locator, so
    # assigning fixed labels to it warns ("FixedFormatter should only be used
    # together with FixedLocator") and silently misaligns if the locator later
    # picks different ticks.
    cbar.ax.yaxis.set_major_formatter(lambda v, _: f"{v:.0%}")
    cbar.ax.yaxis.label.set_color(INK_2)

    # Ring the Friday-daytime notch so a reader knows what they are looking at.
    # An unexplained pale band in a heatmap reads as missing data, not as a finding.
    jummah = [i for i, h in enumerate(hours) if 12 <= h <= 15]
    if jummah:
        ax.add_patch(
            plt.Rectangle(
                (jummah[0] - 0.5, 4 - 0.5),
                len(jummah),
                1,
                fill=False,
                edgecolor=ORANGE,
                linewidth=1.8,
                zorder=5,
            )
        )
        # A surface-coloured plate under the label. Without it the text renders
        # directly on top of the 16:00-17:00 cells (it sits inside the grid, not
        # in a margin — there is no margin on a full-width heatmap) and on first
        # render it fought the cells it was trying to explain.
        ax.annotate(
            "Jummah",
            (jummah[-1] + 0.6, 4),
            color=ORANGE,
            fontsize=9,
            fontweight="600",
            va="center",
            zorder=6,
            bbox=dict(facecolor=SURFACE, edgecolor="none", boxstyle="square,pad=0.25"),
        )


# Panel 5 — price response. The panel that justifies the whole dataset.
def _panel_elasticity(ax, frame: pd.DataFrame) -> None:
    edges = np.arange(0.70, 1.5001, 0.10)
    codes = np.clip(np.digitize(frame["price_ratio"].to_numpy(), edges) - 1, 0, len(edges) - 2)
    centres = (edges[:-1] + edges[1:]) / 2

    # Indexed to each segment's own cheapest bin. Peak and off-peak have very
    # different base rates, and plotting raw rates would make the off-peak line
    # look flat purely because it sits lower — visually contradicting the true
    # finding, which is that off-peak buyers are the more price-sensitive ones.
    # Indexing to a common base is the correct single-axis fix. A second y-axis
    # would be the wrong one.
    for label, colour, mask in (
        ("Peak (18–22h)", BLUE, frame["is_peak"] == 1),
        ("Off-peak", ORANGE, frame["is_peak"] == 0),
    ):
        rates = []
        for b in range(len(centres)):
            sel = mask.to_numpy() & (codes == b)
            rates.append(float(frame.loc[sel, features.TARGET].mean()) if sel.sum() >= 100 else np.nan)
        arr = np.array(rates)
        if np.isnan(arr[0]) or arr[0] == 0:
            continue
        indexed = 100.0 * arr / arr[0]
        ax.plot(centres, indexed, "-o", color=colour, label=label, zorder=3)
        # Label the last bin that has enough rows to plot — thin tail bins
        # are NaN and must not be labelled as if they were measured.
        end = int(np.flatnonzero(~np.isnan(indexed))[-1])
        _annotate(
            ax,
            centres[end],
            indexed[end],
            f"{indexed[end]:.0f}",
            dx=0.03,
            dy=0,
            ha="left",
            va="center",
            color=INK_2,
        )

    ax.axhline(100, color=BASELINE, lw=1.0, zorder=2)
    # Title deliberately short. The full sentence needed ~6in of a 4.9in two-column
    # panel and was clipped at the figure's right edge on first render. This file's
    # convention is claim in the title, reasoning in the xlabel, so it moves down.
    ax.set_title("Price response — off-peak is price-sensitive")
    ax.set_xlabel("offered price ÷ list price · both segments fall, off-peak far faster")
    ax.set_ylabel("booked share, cheapest bin = 100")
    ax.set_xticks(centres, [f"{c:.2f}" for c in centres])
    ax.legend(loc="lower left")


# Assembly.
def render(frame: pd.DataFrame, out: Path, meta: dict | None = None) -> Path:
    """Render the five-panel figure. Returns the path written."""
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)

    with plt.rc_context(_style()):
        fig = plt.figure(figsize=(16.5, 13.5))
        # 6 columns so panels can take thirds and halves. The hour curve gets 2/3
        # because it has 17 x-positions and an argument to make; the heatmap gets
        # the full width because 17 hours x 7 days is unreadable when squeezed.
        gs = GridSpec(
            3, 6, figure=fig, hspace=0.42, wspace=0.55,
            left=0.055, right=0.975, top=0.905, bottom=0.075,
        )
        _panel_hour(fig.add_subplot(gs[0, 0:4]), frame)
        _panel_elasticity(fig.add_subplot(gs[0, 4:6]), frame)
        _panel_dow(fig.add_subplot(gs[1, 0:3]), frame)
        _panel_month(fig.add_subplot(gs[1, 3:6]), frame)
        ax_heat = fig.add_subplot(gs[2, 0:6])
        _panel_heatmap(ax_heat, frame, fig)

        fig.suptitle(
            "SportLynk — simulated demand patterns",
            x=0.055, y=0.972, ha="left", fontsize=17, fontweight="700", color=INK,
        )
        rows = len(frame)
        rate = float(frame[features.TARGET].mean())
        seed = (meta or {}).get("seed", "?")
        window = (meta or {}).get("window", {})
        span = (
            f"{window.get('start', frame['slot_date'].min())} to "
            f"{window.get('end', frame['slot_date'].max())}"
        )
        fig.text(
            0.055, 0.940,
            f"{rows:,} offered slots · {span} · {frame['venue_id'].nunique()} venues · "
            f"{rate:.1%} booked overall · seed {seed}",
            fontsize=10.5, color=INK_2, ha="left",
        )
        # The honesty line. This figure will end up in a report and in a slide
        # deck, and it must carry its own provenance when it is separated from the
        # documents that explain it.
        fig.text(
            0.055, 0.022,
            "SYNTHETIC DATA — no row describes a real booking. Generated by "
            "training/generate_bookings.py; every parameter, its confidence label and this "
            "run's sha256 are in data/bookings_meta.json and documented in data/README.md.",
            fontsize=9, color=MUTED, ha="left",
        )

        fig.savefig(out, dpi=140)
        plt.close(fig)
    return out


def _main(argv: list[str]) -> int:
    csv = Path(argv[1]) if len(argv) > 1 else Path("data/bookings_synth.csv")
    out = Path(argv[2]) if len(argv) > 2 else Path("reports/demand_patterns.png")
    if not csv.exists():
        raise SystemExit(
            f"{csv} not found. Run `python training/generate_bookings.py` first."
        )
    frame = pd.read_csv(csv)
    meta_path = csv.parent / "bookings_meta.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else None
    written = render(frame, out, meta)
    print(f"wrote {written}  ({written.stat().st_size / 1e3:.0f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
