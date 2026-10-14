"""An off-hours sample is set beside the census endpoint by endpoint."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from census_time_of_day import compare


def record(host, network, outcome='ok', height=971_000):
    return dict(host=host, port=8333, network=network, outcome=outcome, startHeight=height)


def keyed(*rows):
    return {(r['host'], r['port']): r for r in rows}


class TimeOfDayTests(unittest.TestCase):
    census = dict(observedTip=971_000, splitHeight=961_632)

    def test_each_paired_endpoint_lands_in_one_cell(self):
        early = keyed(record('a.onion', 'tor'), record('b.onion', 'tor', 'timeout'),
                      record('c.onion', 'tor'), record('d.onion', 'tor', 'timeout'),
                      record('1.1.1.1', 'clearnet', 'noCompactFilters'))
        late = keyed(record('a.onion', 'tor'), record('b.onion', 'tor'),
                     record('c.onion', 'tor', 'timeout'), record('d.onion', 'tor', 'unreachable'),
                     record('2.2.2.2', 'clearnet'))
        table = compare(self.census, early, late)
        self.assertEqual(table['tor'], dict(both=1, sampleOnly=1, censusOnly=1, neither=1))
        self.assertNotIn('clearnet', table)  # 1.1.1.1 and 2.2.2.2 were each dialled once

    def test_odd_endpoints_are_marked_by_what_the_census_saw(self):
        early = keyed(record('s.onion', 'tor', height=961_640), record('h.b32.i2p', 'i2p', height=977_000),
                      record('t.onion', 'tor', 'timeout', height=961_640))
        late = keyed(record('s.onion', 'tor', 'timeout'), record('h.b32.i2p', 'i2p'),
                     record('t.onion', 'tor', height=961_640))
        table = compare(self.census, early, late)
        self.assertEqual(table['atSplit'], dict(censusOnly=1))
        self.assertEqual(table['aheadOfTip'], dict(both=1))
        self.assertEqual(table['tor'], dict(censusOnly=1, sampleOnly=1))


if __name__ == '__main__':
    unittest.main()
