-- A check that calls regexp_like with a cast argument.
CREATE TABLE t (
    z text CHECK (regexp_like(z::text, '^[0-9]+$'))
);

-- A value that satisfies the check.
INSERT INTO t VALUES ('12345');

SELECT z FROM t;
