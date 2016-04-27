#!/usr/bin/env python

from __future__ import print_function
import datetime, sys

if __name__ == '__main__':
    for path in sys.argv[1:]:
        with open(path, 'r') as f:
            rows = [x.replace('t: ', '').split() for x in f.read().split('\n') if x.startswith('t: ')]
        t = [datetime.datetime.strptime(x[0], '%H:%M:%S.%f') for x in rows]
        i = [int(x[1]) for x in rows]
        if len(t) < 2:
            print("%s: ERROR ERROR ERROR" % path)
        else:
            t1 = t[1]
            tN = t[-1]
            i1 = i[1]
            iN = i[-1]
            if t1 > tN:
                # Assume wrap-around
                tN = tN + datetime.timedelta(days = 1)
            print("%s: execution took %s seconds from iterations %s to %s" % (path, (tN - t1).total_seconds(), i1, iN))
