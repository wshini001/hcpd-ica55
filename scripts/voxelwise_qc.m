addpath(fullfile(getenv('FSLDIR'), 'etc', 'matlab'));
runs = {'AP', getenv('HCPD_QC_AP_ICA'); 'PA', getenv('HCPD_QC_PA_ICA')};
assert(all(cellfun(@isfolder, runs(:,2))), 'Set HCPD_QC_AP_ICA and HCPD_QC_PA_ICA.');
[stdmask, ~] = read_avw(fullfile(getenv('FSLDIR'), 'data', ...
    'standard', 'MNI152_T1_2mm_brain_mask'));
stdmask = stdmask(:) > 0;

for k = 1:size(runs,1)
    tag = runs{k,1};
    ica = runs{k,2};
    [mask, ~] = read_avw(fullfile(ica, 'mask'));
    keep = mask(:) > 0;
    assert(any(keep), 'Native FEAT mask is empty.');
    before = masked(fullfile(ica, 'filtered_func_data'), keep);
    after = masked(fullfile(ica, 'filtered_func_data_clean'), keep);
    assert(isequal(size(before), size(after)) && size(before,2)==470);
    assert(all(isfinite(before(:))) && all(isfinite(after(:))), ...
        'Nonfinite data in the native mask.');

    motion = readmatrix(fullfile(ica,'mc','prefiltered_func_data_mcf.par'),'FileType','text');
    assert(isequal(size(motion), [470 6]) && all(isfinite(motion(:))));
    fd = [NaN; sum(abs(diff(motion,1,1)).*[50 50 50 1 1 1],2)];
    dv0 = [NaN, sqrt(mean(diff(before,1,2).^2,1))];
    dv1 = [NaN, sqrt(mean(diff(after,1,2).^2,1))];
    sd0 = std(before,0,2);
    sd1 = std(after,0,2);
    active = find(sd0 > 0);
    assert(~isempty(active), 'No varying voxels in pre-FIX image.');
    rows = active(round(linspace(1,numel(active),min(700,numel(active)))));
    a = (before(rows,:) - mean(before(rows,:),2)) ./ sd0(rows);
    b = (after(rows,:) - mean(after(rows,:),2)) ./ sd0(rows);
    flat = nnz(sd1(active)==0);
    clear before after

    standard = masked(fullfile(ica,'reg_standard','filtered_func_data_clean'),stdmask);
    assert(size(standard,2)==470 && all(isfinite(standard(:))), ...
        'Invalid MNI BOLD time series.');
    coverage = mean(std(standard,0,2)>0);
    clear standard

    f = figure('Visible','off','Position',[100 100 1100 850]);
    tiledlayout(4,1,'TileSpacing','compact');
    x = (1:470);
    nexttile; plot(x,fd); ylabel('FD (mm)'); xlim([1 470]);
    title([tag ' motion and voxelwise QC']);
    nexttile; plot(x,dv0,x,dv1); xlim([1 470]); ylabel('DVARS');
    legend('Before FIX','After FIX','Location','northeast');
    nexttile; imagesc(x,1:numel(rows),a,[-2.5 2.5]); ylabel('Voxels');
    title('Before FIX');
    nexttile; imagesc(x,1:numel(rows),b,[-2.5 2.5]); ylabel('Same voxels');
    title('After FIX, using the same pre-FIX scale'); xlabel('Volume');
    colormap(f,gray(256));
    exportgraphics(f,[tag '_voxelwise_qc.png'],'Resolution',130);
    close(f);

    fprintf(['%s | native voxels=%d | newly flat=%d | median DVARS %.4f -> %.4f' ...
             ' | p95 DVARS %.4f -> %.4f | MNI varying coverage=%.2f%%\n'], ...
         tag, nnz(keep), flat, median(dv0(2:end)), median(dv1(2:end)), ...
         prctile(dv0(2:end),95), prctile(dv1(2:end),95), coverage*100);
end

function y = masked(path, keep)
    [img, dims] = read_avw(path);
    assert(prod(dims(1:3))==numel(keep) && numel(img)==numel(keep)*470, ...
        'Image does not match mask dimensions or frame count.');
    img = reshape(img,numel(keep),470);
    y = single(img(keep,:));
end
