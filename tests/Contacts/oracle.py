"""Independent saved-record checks; never imported by the controller."""
import sqlite3

def contact_snapshot(db):
    with sqlite3.connect(db.as_uri()+'?mode=ro',uri=True) as c:
        return {row[0]:row[1:] for row in c.execute('select ROWID,First,Last,Organization from ABPerson')}

def verify_saved_contact(before, after, fields):
    new=[{'id':identifier,'first':values[0],'last':values[1],'company':values[2]}
         for identifier,values in after.items() if identifier not in before and tuple(values)==tuple(fields)]
    preserved=all(after.get(identifier)==values for identifier,values in before.items())
    return new,preserved
