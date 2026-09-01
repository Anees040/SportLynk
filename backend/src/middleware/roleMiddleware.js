/**
 * Factory function that returns middleware to check user role.
 * Must be used after authMiddleware so req.user exists.
 *
 * Usage: router.post('/bookings', auth, checkRole('player'), controller)
 */
const checkRole = (role) => {
  return (req, res, next) => {
    if (!req.user) {
      return res
        .status(401)
        .json({ success: false, message: 'Unauthorized' });
    }

    if (req.user.role !== role) {
      return res
        .status(403)
        .json({ success: false, message: 'Access denied' });
    }

    next();
  };
};

module.exports = checkRole;
