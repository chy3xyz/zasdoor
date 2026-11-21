import { A } from '@solidjs/router';

import { ROUTE_PATH } from '#ui/constants';
import { useI18n } from '#ui/i18n';

function NotFound() {
  const { t } = useI18n();
  return (
    <div class="flex min-h-screen flex-col items-center justify-center gap-4 bg-base-200">
      <p class="text-7xl font-bold text-base-content/20">404</p>
      <p class="text-lg">{t('notFound.title')}</p>
      <A href={ROUTE_PATH.index} class="btn btn-primary">
        {t('notFound.backHome')}
      </A>
    </div>
  );
}

export default NotFound;