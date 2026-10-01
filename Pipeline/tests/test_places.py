"""metros.yaml, build_places.py and requests_to_places.py (PLAN.md §2 F)."""
import build_places as bp
import requests_to_places as rp


def test_every_place_is_well_formed_and_ids_are_unique():
    places = bp.load_places()
    ids = [p["id"] for p in places]
    assert len(ids) == len(set(ids))
    for p in places:
        assert p["extract"].startswith("north-america/us/"), "USA only for now"
        assert p["places"] and all(", USA" in name for name in p["places"])
        lat, lon = (float(v) for v in str(p["demo"]).split(","))
        assert 18 < lat < 72 and -170 < lon < -60


def test_pending_skips_built_places_and_only_overrides():
    places = [{"id": "a"}, {"id": "b"}, {"id": "c"}]
    assert [p["id"] for p in bp.pending(places, {"a"})] == ["b", "c"]
    assert [p["id"] for p in bp.pending(places, {"a"}, only={"a"})] == ["a"]


def test_build_args_carry_every_place_and_options():
    args = bp.build_args({"id": "boston", "name": "Boston", "places": ["Boston, MA, USA", "Cambridge, MA, USA"],
                          "demo": "42.3554, -71.0605", "survey": None, "min_component": 500},
                         bp.PBF / "massachusetts.osm.pbf")
    assert args.count("--place") == 2 and "--survey" not in args
    assert args[args.index("--demo") + 1] == "42.3554,-71.0605"
    assert args[args.index("--min-component") + 1] == "500"


def test_peak_ram_is_read_from_time_l():
    assert bp.peak_rss_gb("  5312409600  maximum resident set size\n") == 5.31


def test_requests_become_us_proposals_merged_per_city():
    geo = {
        (45.5, -122.7): {"city": "Portland", "state": "Oregon", "country_code": "us"},
        (45.5, -122.6): {"city": "Portland", "state": "Oregon", "country_code": "us"},
        (32.7, -117.2): {"city": "San Diego", "state": "California", "country_code": "us"},
        (43.7, -79.4): {"city": "Toronto", "state": "Ontario", "country_code": "ca", "country": "Canada"},
    }
    cells = {"45.5,-122.7": 5, "45.5,-122.6": 4, "32.7,-117.2": 9, "43.7,-79.4": 30, "40.0,-75.0": 1}
    props, skipped = rp.proposals(cells, {"sandiego"}, 3, lambda la, lo: geo[(la, lo)])
    assert [(p["id"], p["requests"], p["extract"]) for p in props] == [("portland", 9, "north-america/us/oregon")]
    reasons = {s[0]: s[3] for s in skipped}
    assert reasons == {"43.7,-79.4": "outside the USA", "32.7,-117.2": "already in metros.yaml"}
    assert rp.state_extract("California", 37.3, -121.9) == "north-america/us/california/norcal"
    assert rp.state_extract("District of Columbia", 38.9, -77.0) == "north-america/us/district-of-columbia"


def test_a_requested_cell_becomes_one_entry_and_foreign_cells_are_refused(tmp_path):
    geo = {(39.7, -105.0): {"city": "Denver", "state": "Colorado", "country_code": "us"},
           (43.7, -79.4): {"city": "Toronto", "state": "Ontario", "country_code": "ca", "country": "Canada"}}
    entry, why = bp.entry_for_cell("39.7,-105.0", [], lambda la, lo: geo[(la, lo)])
    assert why is None and entry["id"] == "denver" and entry["extract"] == "north-america/us/colorado"
    assert entry["places"] == ["Denver, Colorado, USA"]
    entry2, why2 = bp.entry_for_cell("43.7,-79.4", [], lambda la, lo: geo[(la, lo)])
    assert entry2 is None and why2 == "outside the USA"
    _, dup = bp.entry_for_cell("39.7,-105.0", [{"id": "denver"}], lambda la, lo: geo[(la, lo)])
    assert dup == "already in metros.yaml"
    # Appending keeps the file loadable and the comments intact.
    f = tmp_path / "m.yaml"
    f.write_text("# header comment\nmetros:\n  - id: a\n    name: A\n    extract: north-america/us/x\n    places: [\"A, X, USA\"]\n    demo: 1,2\n")
    bp.append_entry(entry, f)
    import yaml
    data = yaml.safe_load(f.read_text())
    assert [m["id"] for m in data["metros"]] == ["a", "denver"]
    assert f.read_text().startswith("# header comment")
