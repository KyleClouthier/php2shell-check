<?php
// check-php.php  -  shows your exact PHP version once, then deletes itself.
// It sends nothing anywhere. The link below only opens if you click it.
// Upload to your site's main folder, open https://yourdomain.com/check-php.php once, done.
echo 'PHP ' . PHP_VERSION;
echo PHP_VERSION_ID < 80200
  ? '  ->  END OF LIFE, no official update. Upgrade needed.'
  : '  ->  supported. Apply the latest patch for your branch.';
// Remove this file so your version is not left public.
echo @unlink(__FILE__) ? '  (this file has deleted itself)' : '  (please delete this file now)';
$v = PHP_MAJOR_VERSION >= 8 ? PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION : PHP_MAJOR_VERSION;
echo '<p><a href="https://simgen.dev/php-patch-check/?v=' . $v . '&full=' . urlencode(PHP_VERSION) . '#ver">See what this means for your site</a></p>';
