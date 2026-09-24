import unittest
from oracle import verify_saved_contact

class ContactOracleTests(unittest.TestCase):
    def test_renaming_existing_contact_is_not_creation(self):
        before={7:('Mira','Stone','Jev demo')}
        after={7:('Alex','River','Jev demo')}
        self.assertEqual(verify_saved_contact(before,after,after[7]),([],False))

    def test_new_contact_requires_correct_fields_and_preserves_existing(self):
        before={7:('Mira','Stone','Jev demo')}
        fields=('Nora','Ellis','Jev demo')
        after={**before,8:fields}
        new,preserved=verify_saved_contact(before,after,fields)
        self.assertEqual([r['id'] for r in new],[8]);self.assertTrue(preserved)
        self.assertEqual(verify_saved_contact(before,after,('Nora','Wrong','Jev demo'))[0],[])

    def test_new_contact_does_not_excuse_editing_another(self):
        before={7:('Mira','Stone','Jev demo')};fields=('Nora','Ellis','Jev demo')
        after={7:('Alex','River','Jev demo'),8:fields}
        self.assertFalse(verify_saved_contact(before,after,fields)[1])

if __name__=='__main__':unittest.main()
