ukb = getenv('HCPD_ICA55_UKB');
addpath(fullfile(ukb, 'Matlab_package', 'FSLNets'));
addpath(fullfile(ukb, 'Matlab_package', 'L1precision'));
addpath(fullfile(getenv('FSLDIR'), 'etc', 'matlab'));

raw = readmatrix('rfMRI_100.dr/dr_stage1.txt');
assert(isequal(size(raw), [470, 100]) && all(isfinite(raw(:))), ...
    'Expected a finite 470 x 100 spatial-regression result.');

ts = nets_load('rfMRI_100.dr', 0.8, 0, 1, size(raw, 1));
ukb_components = setdiff(1:100, [1 44 47 51 54 55 56 59 61 62 65:92 94:100]);
assert(numel(ukb_components) == 55);
ts.DD = ukb_components;
ts = nets_tsclean(ts, 1);
assert(isequal(size(ts.ts), [470, 55]) && all(isfinite(ts.ts(:))), ...
    'Expected finite ICA55 time series with 470 frames.');

full_net = reshape(nets_netmats(ts, -19.7177, 'corr'), 55, 55);
partial_net = reshape(nets_netmats(ts, -18.8310, 'ridgep', 0.5), 55, 55);
upper = triu(true(55), 1);
[i, j] = find(upper);
full_edges = full_net(upper);
partial_edges = partial_net(upper);
amplitude = std(ts.ts, 0, 1).';
assert(numel(full_edges) == 1485 && numel(partial_edges) == 1485 && ...
    all(isfinite(full_edges)) && all(isfinite(partial_edges)));
assert(numel(amplitude) == 55 && all(isfinite(amplitude)));

writematrix(ts.ts, 'ica55_timeseries.tsv', 'FileType', 'text', 'Delimiter', 'tab');
writetable(table((1:1485).', i, j, ukb_components(i).', ukb_components(j).', ...
    full_edges, partial_edges, 'VariableNames', ...
    {'edge', 'node_i', 'node_j', 'ukb_component_i', 'ukb_component_j', ...
     'fullcorr', 'ridge_partialcorr'}), ...
    'ica55_edges.tsv', 'FileType', 'text', 'Delimiter', 'tab');
writetable(table((1:55).', ukb_components.', amplitude, 'VariableNames', ...
    {'node', 'ukb_component', 'amplitude'}), ...
    'ica55_amplitudes.tsv', 'FileType', 'text', 'Delimiter', 'tab');
fprintf('PASS: ICA55 time series 470 x 55, full and partial edges 1485 each, amplitudes 55.\n');
