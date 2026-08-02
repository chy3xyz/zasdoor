import { useAuth } from '#ui/hooks';
import { formatDateTime } from '#ui/utils';

function Profile() {
  const [auth] = useAuth();
  const user = () => auth.user;

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">个人资料</h2>
        <p class="text-sm text-base-content/60">当前登录账号信息</p>
      </div>

      <div class="card w-full max-w-lg bg-base-100 shadow-sm">
        <div class="card-body gap-3">
          <div class="flex items-center gap-4">
            <div class="avatar placeholder">
              <div class="w-16 rounded-full bg-primary text-neutral-content">
                <span class="text-xl">{(user()?.name ?? '?').slice(0, 1)}</span>
              </div>
            </div>
            <div>
              <p class="text-lg font-semibold">{user()?.name}</p>
              <p class="text-sm text-base-content/60">{user()?.email}</p>
            </div>
          </div>
          <div class="divider my-1" />
          <dl class="space-y-2 text-sm">
            <div class="flex justify-between">
              <dt class="text-base-content/60">用户 ID</dt>
              <dd class="font-mono">{user()?.id}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/60">角色</dt>
              <dd>
                <span class={`badge badge-sm ${user()?.admin ? 'badge-primary' : 'badge-ghost'}`}>
                  {user()?.admin ? '管理员' : '用户'}
                </span>
              </dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/60">验证状态</dt>
              <dd>
                <span class={`badge badge-sm ${user()?.verified ? 'badge-success' : 'badge-outline'}`}>
                  {user()?.verified ? '已验证' : '未验证'}
                </span>
              </dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/60">注册时间</dt>
              <dd>{formatDateTime(user()?.created_at ?? 0)}</dd>
            </div>
            <div class="flex justify-between">
              <dt class="text-base-content/60">更新时间</dt>
              <dd>{formatDateTime(user()?.updated_at ?? 0)}</dd>
            </div>
          </dl>
        </div>
      </div>
    </div>
  );
}

export default Profile;
