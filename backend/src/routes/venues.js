const router = require('express').Router();
const ctrl = require('../controllers/venueController');

// All venue routes are public (no auth required)
router.get('/', ctrl.searchVenues);
router.get('/:id', ctrl.getVenueById);
router.get('/:id/slots', ctrl.getVenueSlots);

module.exports = router;
